import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:provider/provider.dart';
import '../models/location_update.dart';
import '../services/nearby_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  Timer? _refreshTimer;
  DateTime? _lastUpdated;
  bool _isAcquiring = false;
  String? _locationError;
  double _heading = 0.0; // degrees from north
  StreamSubscription<CompassEvent>? _compassSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    // Refresh UI every 5 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() => _lastUpdated = DateTime.now());
    });

    // Subscribe to compass heading
    _compassSub = FlutterCompass.events?.listen((event) {
      final h = event.heading;
      if (h != null && mounted) {
        setState(() => _heading = h);
      }
    });

    // Auto-acquire location when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _acquireLocation();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _refreshTimer?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  Future<void> _acquireLocation() async {
    if (_isAcquiring || !mounted) return;
    setState(() {
      _isAcquiring = true;
      _locationError = null;
    });
    try {
      final service = Provider.of<NearbyService>(context, listen: false);
      await service.startLocationBroadcast();
      if (mounted) {
        setState(() {
          _isAcquiring = false;
          _lastUpdated = DateTime.now();
          if (service.myLocation == null) {
            _locationError = 'Could not get GPS fix.\nEnsure location is enabled and try again.';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAcquiring = false;
          _locationError = 'Location error. Tap the button to retry.';
        });
      }
    }
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '—';
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, service, _) {
        final myLoc = service.myLocation;
        final peers = service.peerLocations.values.toList();
        final survivorCount = peers.length + (myLoc != null ? 1 : 0);

        return Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          appBar: AppBar(
            backgroundColor: const Color(0xFF16213E),
            title: const Text('Live Survivor Map',
                style: TextStyle(color: Colors.white)),
            iconTheme: const IconThemeData(color: Colors.white),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(28),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.people, size: 14, color: Colors.orange),
                    const SizedBox(width: 4),
                    Text(
                      '$survivorCount located survivor${survivorCount == 1 ? '' : 's'}',
                      style: const TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                    const SizedBox(width: 16),
                    const Icon(Icons.update, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      'Updated ${_formatTime(_lastUpdated ?? DateTime.now())}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: myLoc == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isAcquiring) ...
                        [
                          const CircularProgressIndicator(color: Colors.orange),
                          const SizedBox(height: 16),
                          const Text(
                            'Acquiring location…',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Make sure location services are enabled.',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ]
                      else ...
                        [
                          const Icon(Icons.location_off, color: Colors.orange, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            _locationError ?? 'Location unavailable.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton.icon(
                            onPressed: _acquireLocation,
                            icon: const Icon(Icons.my_location),
                            label: const Text('Retry'),
                          ),
                        ],
                    ],
                  ),
                )
              : AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _MeshMapPainter(
                        myLocation: myLoc,
                        peers: peers,
                        pulseValue: _pulseController.value,
                        heading: _heading,
                      ),
                      child: const SizedBox.expand(),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton.small(
            backgroundColor: Colors.orange,
            onPressed: _isAcquiring ? null : _acquireLocation,
            tooltip: 'Broadcast my location now',
            child: _isAcquiring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.my_location, color: Colors.white),
          ),
        );
      },
    );
  }
}

class _MeshMapPainter extends CustomPainter {
  final LocationUpdate myLocation;
  final List<LocationUpdate> peers;
  final double pulseValue;
  final double heading; // degrees clockwise from north

  // Visible radius in degrees (~500 m each side)
  static const double _viewRange = 0.005;

  _MeshMapPainter({
    required this.myLocation,
    required this.peers,
    required this.pulseValue,
    required this.heading,
  });

  Offset _toCanvas(Size size, double lat, double lon) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = size.width / (2 * _viewRange);
    // Longitude compression at current latitude
    final lonScale = scale * cos(myLocation.latitude * pi / 180);

    final dx = (lon - myLocation.longitude) * lonScale;
    final dy = (myLocation.latitude - lat) * scale; // lat up = y down
    return Offset(cx + dx, cy + dy);
  }

  void _drawDot({
    required Canvas canvas,
    required Offset center,
    required Color color,
    required double radius,
    required String label,
    double pulseRadius = 0,
    Color? pulseColor,
  }) {
    // Pulse ring for SOS
    if (pulseRadius > 0 && pulseColor != null) {
      canvas.drawCircle(
        center,
        pulseRadius,
        Paint()
          ..color = pulseColor.withOpacity(0.4 * (1 - pulseRadius / 28))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // Shadow
    canvas.drawCircle(
      center,
      radius + 3,
      Paint()..color = Colors.black38,
    );

    // Fill
    canvas.drawCircle(center, radius, Paint()..color = color);

    // Label
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(blurRadius: 3, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy + radius + 3),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF1A1A2E),
    );

    // Grid lines (every 0.001 deg ≈ 100 m)
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 0.5;
    final scale = size.width / (2 * _viewRange);
    const gridStep = 0.001;
    final cx = size.width / 2;
    final cy = size.height / 2;

    for (var i = -5; i <= 5; i++) {
      final x = cx + i * gridStep * scale;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      final y = cy + i * gridStep * scale;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Scale bar (bottom-left)
    final barMeters = 100;
    final barPx = barMeters / 111000 * scale;
    final barY = size.height - 24.0;
    final barX = 20.0;
    final barPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 2;
    canvas.drawLine(Offset(barX, barY), Offset(barX + barPx, barY), barPaint);
    canvas.drawLine(Offset(barX, barY - 4), Offset(barX, barY + 4), barPaint);
    canvas.drawLine(Offset(barX + barPx, barY - 4),
        Offset(barX + barPx, barY + 4), barPaint);
    final scaleTp = TextPainter(
      text: const TextSpan(
        text: '100 m',
        style: TextStyle(color: Colors.white70, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    scaleTp.paint(canvas, Offset(barX + barPx / 2 - scaleTp.width / 2, barY + 6));

    // Peer dots
    for (final peer in peers) {
      final pos = _toCanvas(size, peer.latitude, peer.longitude);
      final pulseR = peer.isSOS ? 10.0 + pulseValue * 18.0 : 0.0;
      _drawDot(
        canvas: canvas,
        center: pos,
        color: peer.isSOS ? Colors.red : Colors.orange,
        radius: 8,
        label: peer.userName,
        pulseRadius: pulseR,
        pulseColor: Colors.red,
      );
    }

    // My arrow (always on center, rotates with heading)
    _drawArrow(
      canvas: canvas,
      center: Offset(size.width / 2, size.height / 2),
      headingDeg: heading,
    );

    // Compass rose (top-right) — needle points to true north
    final compassCenter = Offset(size.width - 36, 48);
    _drawCompassRose(canvas, compassCenter, heading);
  }

  @override
  bool shouldRepaint(_MeshMapPainter old) =>
      old.pulseValue != pulseValue ||
      old.peers.length != peers.length ||
      old.myLocation.latitude != myLocation.latitude ||
      old.heading != heading;

  /// Draws a teardrop/chevron arrow centred at [center], pointing toward
  /// [headingDeg] degrees clockwise from north (up on the map).
  void _drawArrow({
    required Canvas canvas,
    required Offset center,
    required double headingDeg,
  }) {
    // Convert heading to canvas rotation:
    // heading 0 (north) = up = -Y axis on canvas
    // rotate canvas by headingDeg so our "up" arrow points the right way
    final rad = headingDeg * pi / 180;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rad);

    // Glow / accuracy circle
    canvas.drawCircle(
      Offset.zero,
      22,
      Paint()..color = Colors.blueAccent.withOpacity(0.15),
    );

    // Arrow body (pointing up = north when heading=0)
    final arrowPath = Path()
      ..moveTo(0, -16)        // tip
      ..lineTo(10, 10)        // right base
      ..lineTo(0, 5)          // center notch
      ..lineTo(-10, 10)       // left base
      ..close();

    // Shadow
    canvas.drawPath(
      arrowPath.shift(const Offset(1.5, 1.5)),
      Paint()..color = Colors.black38,
    );

    // Fill: front half blue, rear half lighter to give 3-D sense
    canvas.drawPath(arrowPath, Paint()..color = Colors.blueAccent);

    // Centre dot
    canvas.drawCircle(
      Offset.zero,
      4,
      Paint()..color = Colors.white,
    );

    canvas.restore();

    // "You" label below the arrow
    final tp = TextPainter(
      text: const TextSpan(
        text: 'You',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(blurRadius: 3, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + 20));
  }

  /// Draws a compass rose whose needle always points to geographic north,
  /// compensating for the device's current [headingDeg].
  void _drawCompassRose(Canvas canvas, Offset center, double headingDeg) {
    final rad = headingDeg * pi / 180;

    // Outer ring
    canvas.drawCircle(
      center,
      22,
      Paint()..color = Colors.white.withOpacity(0.12),
    );
    canvas.drawCircle(
      center,
      22,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    canvas.save();
    canvas.translate(center.dx, center.dy);
    // Rotate the needle opposite to heading so it always points to true north
    canvas.rotate(-rad);

    // North needle (red)
    canvas.drawPath(
      Path()
        ..moveTo(0, -15)
        ..lineTo(4, 0)
        ..lineTo(0, 3)
        ..lineTo(-4, 0)
        ..close(),
      Paint()..color = Colors.red,
    );

    // South needle (white/grey)
    canvas.drawPath(
      Path()
        ..moveTo(0, 15)
        ..lineTo(4, 0)
        ..lineTo(0, -3)
        ..lineTo(-4, 0)
        ..close(),
      Paint()..color = Colors.white54,
    );

    // Centre pin
    canvas.drawCircle(Offset.zero, 3, Paint()..color = Colors.white);

    canvas.restore();

    // "N" label above the rose
    final nTp = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(
          color: Colors.red,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    nTp.paint(
      canvas,
      Offset(center.dx - nTp.width / 2, center.dy - 38),
    );
  }}