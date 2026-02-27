import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/roll_call.dart';
import '../services/nearby_service.dart';

// ─── Coordinator Screen ───────────────────────────────────────────────────────

class RollCallScreen extends StatefulWidget {
  const RollCallScreen({super.key});

  @override
  State<RollCallScreen> createState() => _RollCallScreenState();
}

class _RollCallScreenState extends State<RollCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _clockTimer;
  int _secondsLeft = 60;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _startRollCall();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _startRollCall() async {
    if (_starting) return;
    _starting = true;
    final service = Provider.of<NearbyService>(context, listen: false);
    await service.startRollCall();
    _resetClock(service.activeRollCall?.deadline);
  }

  void _resetClock(DateTime? deadline) {
    _clockTimer?.cancel();
    if (deadline == null) return;
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final secs = deadline.difference(DateTime.now()).inSeconds;
      if (mounted) setState(() => _secondsLeft = secs.clamp(0, 60));
    });
  }

  Future<void> _stopAndPop() async {
    final service = Provider.of<NearbyService>(context, listen: false);
    service.stopRollCall();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, service, _) {
        final rc = service.activeRollCall;

        if (rc == null) {
          return Scaffold(
            backgroundColor: const Color(0xFF0D1423),
            appBar: AppBar(
              backgroundColor: const Color(0xFF0D1423),
              title: const Text('Roll Call', style: TextStyle(color: Colors.white)),
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: const Center(
              child: CircularProgressIndicator(color: Colors.cyanAccent),
            ),
          );
        }

        // Check if deadline has been reset (new round)
        final now = DateTime.now();
        final secsLeft = rc.deadline.difference(now).inSeconds.clamp(0, 60);
        final progress = secsLeft / 60.0;

        return WillPopScope(
          onWillPop: () async {
            await _stopAndPop();
            return false;
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF0D1423),
            appBar: AppBar(
              backgroundColor: const Color(0xFF0D1423),
              title: Text(
                'Roll Call — Round ${rc.round}',
                style: const TextStyle(color: Colors.white),
              ),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                TextButton.icon(
                  onPressed: _stopAndPop,
                  icon: const Icon(Icons.stop_circle_rounded, color: Colors.redAccent),
                  label: const Text('Stop', style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
            body: Column(
              children: [
                // ── Countdown ring + summary ────────────────────────────────
                Container(
                  color: const Color(0xFF101828),
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Countdown ring
                      SizedBox(
                        width: 110,
                        height: 110,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CustomPaint(
                              size: const Size(110, 110),
                              painter: _RingPainter(
                                progress: progress,
                                color: _ringColor(secsLeft),
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  secsLeft > 0 ? '$secsLeft' : '0',
                                  style: TextStyle(
                                    color: _ringColor(secsLeft),
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Text(
                                  'sec',
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 11),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Response summary
                      Column(
                        children: [
                          _StatBox(
                              rc.responded,
                              rc.total,
                              'Responded',
                              Colors.cyanAccent),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _MiniStat(rc.safeCount, 'Safe',
                                  const Color(0xFF43A047)),
                              const SizedBox(width: 10),
                              _MiniStat(rc.helpCount, 'Need Help',
                                  const Color(0xFFE53935)),
                              const SizedBox(width: 10),
                              _MiniStat(rc.unknownCount, 'Unknown',
                                  Colors.grey),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Auto-repeat notice
                Container(
                  width: double.infinity,
                  color: Colors.white.withOpacity(0.04),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    rc.allResponded
                        ? '✓ All accounted for — next round in 2 min'
                        : 'Auto-repeats every 2 min  •  No-response → flagged Unknown',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),

                // ── Roster list ─────────────────────────────────────────────
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'ROSTER',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                Expanded(
                  child: rc.entries.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_off_rounded,
                                  color: Colors.white24, size: 48),
                              SizedBox(height: 12),
                              Text(
                                'No connected devices\nto call roll for',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 14),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          itemCount: rc.entries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (context, i) {
                            final entry =
                                rc.entries.values.elementAt(i);
                            return _RosterTile(
                                entry: entry, pulse: _pulse);
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _ringColor(int secsLeft) {
    if (secsLeft > 30) return Colors.cyanAccent;
    if (secsLeft > 10) return Colors.orangeAccent;
    return Colors.redAccent;
  }
}

// ─── Ring painter ─────────────────────────────────────────────────────────────

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = min(cx, cy) - 6;

    // Track
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..color = Colors.white.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );

    // Progress arc
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -pi / 2,
      2 * pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

// ─── Roster tile ──────────────────────────────────────────────────────────────

class _RosterTile extends StatelessWidget {
  final RollCallEntry entry;
  final AnimationController pulse;

  const _RosterTile({required this.entry, required this.pulse});

  @override
  Widget build(BuildContext context) {
    final color = Color(entry.status.colorValue);
    final isNeedHelp = entry.status == RollCallEntryStatus.needHelp;

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final glowOpacity =
            isNeedHelp ? 0.15 + pulse.value * 0.25 : 0.0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08 + glowOpacity),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withOpacity(isNeedHelp ? 0.5 + pulse.value * 0.4 : 0.25),
              width: isNeedHelp ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: isNeedHelp
                      ? [BoxShadow(color: color.withOpacity(0.6), blurRadius: 8)]
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (entry.respondedAt != null)
                Text(
                  '${entry.respondedAt!.hour.toString().padLeft(2, '0')}:'
                  '${entry.respondedAt!.minute.toString().padLeft(2, '0')}:'
                  '${entry.respondedAt!.second.toString().padLeft(2, '0')}',
                  style: TextStyle(color: color.withOpacity(0.6), fontSize: 11),
                ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: color.withOpacity(0.5), width: 1),
                ),
                child: Text(
                  entry.status.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Summary widgets ──────────────────────────────────────────────────────────

class _StatBox extends StatelessWidget {
  final int value;
  final int total;
  final String label;
  final Color color;

  const _StatBox(this.value, this.total, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RichText(
          text: TextSpan(
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
            children: [
              TextSpan(
                  text: '$value',
                  style: const TextStyle(fontSize: 28)),
              TextSpan(
                  text: ' / $total',
                  style: const TextStyle(
                      fontSize: 16, color: Colors.white38)),
            ],
          ),
        ),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final int value;
  final String label;
  final Color color;

  const _MiniStat(this.value, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value',
            style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    );
  }
}
