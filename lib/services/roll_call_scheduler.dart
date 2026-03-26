import 'dart:async';
import 'package:flutter/material.dart';
import '../services/nearby_service.dart';
import '../services/notification_service.dart';

/// Schedules automatic roll calls every 5 minutes and shows a global
/// full-screen overlay whenever an incoming roll call is received,
/// regardless of which screen the user is on.
class RollCallScheduler {
  RollCallScheduler(this._nearby);

  final NearbyService _nearby;
  Timer? _timer;
  OverlayEntry? _overlayEntry;

  /// Start the 5-minute periodic roll call timer.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_nearby.connectedDevices.isNotEmpty) {
        _nearby.startRollCall();
      }
    });
    // Also listen for incoming roll calls to show global overlay
    _nearby.addListener(_onNearbyChanged);
  }

  void dispose() {
    _timer?.cancel();
    _nearby.removeListener(_onNearbyChanged);
    _removeOverlay();
  }

  // The overlay key lets us insert on top of all routes.
  late final GlobalKey<NavigatorState> navigatorKey;

  void _onNearbyChanged() {
    if (_nearby.incomingRollCall != null && _overlayEntry == null) {
      _showOverlay();
      // Also show notification with action buttons
      NotificationService.instance.showRollCallNotification(
        _nearby.incomingRollCall?.coordinatorName ?? 'Someone',
      );
    } else if (_nearby.incomingRollCall == null && _overlayEntry != null) {
      _removeOverlay();
      NotificationService.instance.cancelRollCallNotification();
    }
  }

  void _showOverlay() {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _overlayEntry = OverlayEntry(
      builder: (_) => _GlobalRollCallOverlay(
        service: _nearby,
        onDismiss: _removeOverlay,
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }
}

/// Full-screen roll call responder overlay shown on top of everything.
class _GlobalRollCallOverlay extends StatefulWidget {
  final NearbyService service;
  final VoidCallback onDismiss;
  const _GlobalRollCallOverlay({required this.service, required this.onDismiss});

  @override
  State<_GlobalRollCallOverlay> createState() => _GlobalRollCallOverlayState();
}

class _GlobalRollCallOverlayState extends State<_GlobalRollCallOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _clock;
  int _secsLeft = 60;
  bool _responding = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _secsLeft = widget.service.incomingRollCall?.deadlineSecs ?? 60;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secsLeft = (_secsLeft - 1).clamp(0, 999));
    });
    widget.service.addListener(_onServiceChanged);
  }

  void _onServiceChanged() {
    if (widget.service.incomingRollCall == null) {
      widget.onDismiss();
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    _pulse.dispose();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _respond(String status) async {
    if (_responding) return;
    setState(() => _responding = true);
    await widget.service.respondToRollCall(status);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final glow = _pulse.value;
        return Material(
          color: Colors.black.withValues(alpha: 0.92),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.deepPurple.withValues(alpha: 0.2 + glow * 0.2),
                      border: Border.all(
                        color: Colors.deepPurpleAccent.withValues(alpha: 0.6 + glow * 0.4),
                        width: 2,
                      ),
                    ),
                    child: const Icon(Icons.how_to_reg_rounded,
                        color: Colors.deepPurpleAccent, size: 36),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'ROLL CALL',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${widget.service.incomingRollCall?.coordinatorName ?? ''} is checking everyone\'s status',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 14),
                  ),
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.timer_rounded, color: Colors.white38, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          '$_secsLeft seconds to respond',
                          style: TextStyle(
                            color: _secsLeft < 15 ? Colors.redAccent : Colors.white60,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  if (_responding)
                    const CircularProgressIndicator(color: Colors.deepPurpleAccent)
                  else
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _respond('safe'),
                            child: Container(
                              height: 90,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1B5E20),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: Colors.greenAccent.withValues(alpha: 0.6),
                                    width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.green.withValues(alpha: 0.3 + glow * 0.2),
                                    blurRadius: 16 + glow * 12,
                                  ),
                                ],
                              ),
                              child: const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.check_circle_rounded,
                                      color: Colors.greenAccent, size: 32),
                                  SizedBox(height: 6),
                                  Text("I'M SAFE",
                                      style: TextStyle(
                                        color: Colors.greenAccent,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      )),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _respond('needHelp'),
                            child: Container(
                              height: 90,
                              decoration: BoxDecoration(
                                color: const Color(0xFF7F0000),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: Colors.redAccent.withValues(alpha: 0.6),
                                    width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.3 + glow * 0.3),
                                    blurRadius: 16 + glow * 16,
                                  ),
                                ],
                              ),
                              child: const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.warning_rounded,
                                      color: Colors.redAccent, size: 32),
                                  SizedBox(height: 6),
                                  Text('NEED HELP',
                                      style: TextStyle(
                                        color: Colors.redAccent,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      )),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 20),
                  const Text(
                    'No response = flagged Unknown after timeout',
                    style: TextStyle(color: Colors.white24, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
