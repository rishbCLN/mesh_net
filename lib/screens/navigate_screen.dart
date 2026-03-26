import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:provider/provider.dart';
import '../models/location_update.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';

/// Full-screen compass-arrow navigation toward a selected survivor.
class NavigateScreen extends StatefulWidget {
  final LocationUpdate target;

  const NavigateScreen({super.key, required this.target});

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  StreamSubscription<CompassEvent>? _compassSub;
  double _heading = 0.0; // device heading (degrees from true north)
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _compassSub = FlutterCompass.events?.listen((event) {
      final h = event.heading;
      if (h != null && mounted) {
        setState(() => _heading = h);
      }
    });

    // Periodic refresh so distance updates as GPS updates
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });

    // Haptic on open
    HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _compassSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Bearing from point A to point B in degrees (0 = north, 90 = east).
  double _bearingTo(double lat1, double lon1, double lat2, double lon2) {
    final dLon = (lon2 - lon1) * pi / 180.0;
    final la1 = lat1 * pi / 180.0;
    final la2 = lat2 * pi / 180.0;
    final y = sin(dLon) * cos(la2);
    final x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon);
    final bearing = atan2(y, x) * 180.0 / pi;
    return (bearing + 360) % 360;
  }

  /// Haversine distance in meters.
  double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a1 = lat1 * pi / 180.0;
    final a2 = lat2 * pi / 180.0;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(a1) * cos(a2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return earthRadius * c;
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, service, _) {
        final myLoc = service.myLocation;
        final target = widget.target;

        // Try to get a fresher target location from peer updates
        final freshTarget =
            service.peerLocations[target.userId] ?? target;

        double bearing = 0;
        double distance = 0;
        bool hasLocation = myLoc != null;

        if (hasLocation) {
          bearing = _bearingTo(
            myLoc.latitude,
            myLoc.longitude,
            freshTarget.latitude,
            freshTarget.longitude,
          );
          distance = _distanceMeters(
            myLoc.latitude,
            myLoc.longitude,
            freshTarget.latitude,
            freshTarget.longitude,
          );
        }

        // Arrow rotation = bearing - heading (so arrow points to target
        // relative to where the device is facing)
        final arrowAngle = (bearing - _heading) * pi / 180.0;

        final statusColor = freshTarget.triageStatus.color;
        final isAlert = freshTarget.triageStatus == TriageStatus.sos ||
            freshTarget.triageStatus == TriageStatus.critical;

        return Scaffold(
          backgroundColor: const Color(0xFF0D1020),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0D1020),
            title: Text(
              'Navigate to ${freshTarget.userName}',
              style: const TextStyle(color: Colors.white),
            ),
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: !hasLocation
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_searching,
                          color: Colors.orange, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'Acquiring your GPS location…',
                        style: TextStyle(color: Colors.white60, fontSize: 16),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => service.startLocationBroadcast(),
                        icon: const Icon(Icons.my_location),
                        label: const Text('Retry GPS'),
                      ),
                    ],
                  )
                : AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) {
                      final glow = _pulse.value;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Target info card
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 32),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: statusColor.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(freshTarget.triageStatus.icon,
                                    color: statusColor, size: 22),
                                const SizedBox(width: 10),
                                Text(
                                  '${freshTarget.userName} — ${freshTarget.triageStatus.label}',
                                  style: TextStyle(
                                    color: statusColor,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 40),

                          // Distance
                          Text(
                            _formatDistance(distance),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 56,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              shadows: [
                                Shadow(
                                  blurRadius: 20,
                                  color: statusColor
                                      .withValues(alpha: 0.5 + glow * 0.3),
                                ),
                              ],
                            ),
                          ),
                          const Text(
                            'away',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 16),
                          ),
                          const SizedBox(height: 48),

                          // Compass arrow
                          SizedBox(
                            width: 200,
                            height: 200,
                            child: CustomPaint(
                              painter: _ArrowPainter(
                                angle: arrowAngle,
                                color: statusColor,
                                glowValue: isAlert ? glow : 0,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Bearing text
                          Text(
                            '${bearing.toStringAsFixed(0)}° from north',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 13),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.explore,
                                  size: 14, color: Colors.white24),
                              const SizedBox(width: 4),
                              Text(
                                'Device heading: ${_heading.toStringAsFixed(0)}°',
                                style: const TextStyle(
                                    color: Colors.white24, fontSize: 12),
                              ),
                            ],
                          ),
                          const SizedBox(height: 40),

                          // GPS coords
                          Text(
                            '${freshTarget.latitude.toStringAsFixed(5)}, '
                            '${freshTarget.longitude.toStringAsFixed(5)}',
                            style: const TextStyle(
                                color: Colors.white24, fontSize: 11),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}

/// CustomPainter that draws a large directional arrow.
class _ArrowPainter extends CustomPainter {
  final double angle; // radians
  final Color color;
  final double glowValue;

  const _ArrowPainter({
    required this.angle,
    required this.color,
    this.glowValue = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = min(cx, cy);

    // Outer ring
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.08 + glowValue * 0.08)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Inner ring
    canvas.drawCircle(
      Offset(cx, cy),
      radius * 0.75,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.04)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(angle);

    // Arrow shape — large chevron
    final arrowPath = Path()
      ..moveTo(0, -radius * 0.65) // tip
      ..lineTo(radius * 0.35, radius * 0.35) // right
      ..lineTo(0, radius * 0.15) // center notch
      ..lineTo(-radius * 0.35, radius * 0.35) // left
      ..close();

    // Glow shadow
    if (glowValue > 0) {
      canvas.drawPath(
        arrowPath,
        Paint()
          ..color = color.withValues(alpha: 0.3 + glowValue * 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }

    // Shadow
    canvas.drawPath(
      arrowPath.shift(const Offset(2, 2)),
      Paint()..color = Colors.black45,
    );

    // Fill
    canvas.drawPath(
      arrowPath,
      Paint()..color = color,
    );

    // Highlight on left edge
    canvas.drawPath(
      Path()
        ..moveTo(0, -radius * 0.65)
        ..lineTo(-radius * 0.35, radius * 0.35)
        ..lineTo(0, radius * 0.15)
        ..close(),
      Paint()..color = Colors.white.withValues(alpha: 0.15),
    );

    canvas.restore();

    // Center dot
    canvas.drawCircle(
      Offset(cx, cy),
      6,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.angle != angle || old.color != color || old.glowValue != glowValue;
}
