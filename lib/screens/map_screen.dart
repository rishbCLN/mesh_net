import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
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
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _refreshTimer?.cancel();
    super.dispose();
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
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.orange),
                      SizedBox(height: 16),
                      Text(
                        'Acquiring location…',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Make sure location services are enabled.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
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
                      ),
                      child: const SizedBox.expand(),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton.small(
            backgroundColor: Colors.orange,
            onPressed: () {
              final service =
                  Provider.of<NearbyService>(context, listen: false);
              service.startLocationBroadcast();
              setState(() => _lastUpdated = DateTime.now());
            },
            tooltip: 'Broadcast my location now',
            child: const Icon(Icons.my_location, color: Colors.white),
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

  // Visible radius in degrees (~500 m each side)
  static const double _viewRange = 0.005;

  _MeshMapPainter({
    required this.myLocation,
    required this.peers,
    required this.pulseValue,
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

    // My dot (always on center)
    _drawDot(
      canvas: canvas,
      center: Offset(size.width / 2, size.height / 2),
      color: Colors.blueAccent,
      radius: 10,
      label: 'You',
    );

    // Compass (top-right)
    final compassCenter = Offset(size.width - 30, 40);
    canvas.drawCircle(
        compassCenter, 18, Paint()..color = Colors.white.withOpacity(0.1));
    final northTp = TextPainter(
      text: const TextSpan(
          text: 'N', style: TextStyle(color: Colors.white70, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    northTp.paint(
        canvas,
        Offset(compassCenter.dx - northTp.width / 2,
            compassCenter.dy - 17));
  }

  @override
  bool shouldRepaint(_MeshMapPainter old) =>
      old.pulseValue != pulseValue ||
      old.peers.length != peers.length ||
      old.myLocation.latitude != myLocation.latitude;
}
