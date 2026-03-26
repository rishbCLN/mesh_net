import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:provider/provider.dart';
import '../models/location_update.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';
import 'navigate_screen.dart';

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
  double _zoom = 1.0;
  double _zoomStart = 1.0;
  StreamSubscription<CompassEvent>? _compassSub;
  LocationUpdate? _selectedPeer;

  static const double _minZoom = 0.8;
  static const double _maxZoom = 8.0;

  void _changeZoom(double delta) {
    setState(() {
      _zoom = (_zoom + delta).clamp(_minZoom, _maxZoom);
    });
  }

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
    if (t == null) return 'â€”';
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
        peers.sort((a, b) => _distanceMeters(myLoc, a).compareTo(_distanceMeters(myLoc, b)));
        final survivorCount = peers.length + (myLoc != null ? 1 : 0);
        final sosCount = peers.where((p) =>
            p.triageStatus == TriageStatus.sos || p.isSOS).length;
        final critCount = peers.where((p) =>
            p.triageStatus == TriageStatus.critical).length;

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
                    if (sosCount > 0) ...[
                      const SizedBox(width: 16),
                      Icon(Icons.warning_rounded,
                          size: 14, color: TriageStatus.sos.color),
                      const SizedBox(width: 4),
                      Text(
                        '$sosCount TRAPPED',
                        style: TextStyle(
                            color: TriageStatus.sos.color,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                    if (critCount > 0) ...[
                      const SizedBox(width: 12),
                      Icon(Icons.local_hospital_rounded,
                          size: 14, color: TriageStatus.critical.color),
                      const SizedBox(width: 4),
                      Text(
                        '$critCount CRITICAL',
                        style: TextStyle(
                            color: TriageStatus.critical.color,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
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
                            'Acquiring locationâ€¦',
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
              : Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: (_) {
                        _zoomStart = _zoom;
                      },
                      onScaleUpdate: (details) {
                        setState(() {
                          _zoom = (_zoomStart * details.scale).clamp(_minZoom, _maxZoom);
                        });
                      },
                      onTapUp: (details) => _onMapTap(details, myLoc, peers),
                      child: AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, _) {
                          return CustomPaint(
                            painter: _MeshMapPainter(
                              myLocation: myLoc,
                              peers: peers,
                              pulseValue: _pulseController.value,
                              heading: _heading,
                              myTriageStatus: service.myTriageStatus,
                              zoom: _zoom,
                            ),
                            child: const SizedBox.expand(),
                          );
                        },
                      ),
                    ),
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Zoom ${_zoom.toStringAsFixed(1)}x',
                              style: const TextStyle(color: Colors.white, fontSize: 11),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: OutlinedButton(
                                    onPressed: () => _changeZoom(-0.4),
                                    style: OutlinedButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      side: const BorderSide(color: Colors.white54),
                                    ),
                                    child: const Icon(Icons.remove, size: 16, color: Colors.white),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: OutlinedButton(
                                    onPressed: () => _changeZoom(0.4),
                                    style: OutlinedButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      side: const BorderSide(color: Colors.white54),
                                    ),
                                    child: const Icon(Icons.add, size: 16, color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Triage legend (bottom-right)
                    Positioned(
                      bottom: 72,
                      right: 12,
                      child: _TriageLegend(),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 72,
                      child: _NearbyDistancePanel(
                        myLocation: myLoc,
                        peers: peers,
                      ),
                    ),
                    // Selected peer navigation panel
                    if (_selectedPeer != null)
                      Positioned(
                        left: 12,
                        right: 12,
                        top: 12,
                        child: _NavigatePanel(
                          peer: _selectedPeer!,
                          myLocation: myLoc,
                          onNavigate: () {
                            final peer = _selectedPeer!;
                            setState(() => _selectedPeer = null);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => NavigateScreen(target: peer),
                              ),
                            );
                          },
                          onDismiss: () => setState(() => _selectedPeer = null),
                        ),
                      ),
                  ],
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

  double _distanceMeters(LocationUpdate? a, LocationUpdate b) {
    if (a == null) return 0;
    const earthRadius = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return earthRadius * c;
  }

  void _onMapTap(TapUpDetails details, LocationUpdate myLoc, List<LocationUpdate> peers) {
    final size = (context.findRenderObject() as RenderBox).size;
    // Account for AppBar offset by using local position from the GestureDetector
    final tapPos = details.localPosition;
    const baseViewRange = 0.005;
    final viewRange = baseViewRange / _zoom;
    final scale = size.width / (2 * viewRange);
    final lonScale = scale * cos(myLoc.latitude * pi / 180);
    final cx = size.width / 2;
    final cy = size.height / 2;

    const hitRadius = 30.0;
    LocationUpdate? hit;
    double bestDist = hitRadius;

    for (final peer in peers) {
      final dx = (peer.longitude - myLoc.longitude) * lonScale;
      final dy = (myLoc.latitude - peer.latitude) * scale;
      final peerPos = Offset(cx + dx, cy + dy);
      final dist = (peerPos - tapPos).distance;
      if (dist < bestDist) {
        bestDist = dist;
        hit = peer;
      }
    }

    setState(() => _selectedPeer = hit);
  }
}

class _MeshMapPainter extends CustomPainter {
  final LocationUpdate myLocation;
  final List<LocationUpdate> peers;
  final double pulseValue;
  final double heading; // degrees clockwise from north
  final TriageStatus myTriageStatus;
  final double zoom;

  // Base visible radius in degrees (~555 m each side at equator)
  static const double _baseViewRange = 0.005;

  _MeshMapPainter({
    required this.myLocation,
    required this.peers,
    required this.pulseValue,
    required this.heading,
    required this.myTriageStatus,
    required this.zoom,
  });

  double get _viewRange => _baseViewRange / zoom;

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
          ..color = pulseColor.withValues(alpha: 0.4 * (1 - pulseRadius / 28))
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

  double _distanceMetersToPeer(LocationUpdate peer) {
    const earthRadius = 6371000.0;
    final dLat = (peer.latitude - myLocation.latitude) * pi / 180.0;
    final dLon = (peer.longitude - myLocation.longitude) * pi / 180.0;
    final lat1 = myLocation.latitude * pi / 180.0;
    final lat2 = peer.latitude * pi / 180.0;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return earthRadius * c;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF1A1A2E),
    );

    // Grid lines (every 0.001 deg â‰ˆ 100 m)
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
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
    final metersAcross = _viewRange * 2 * 111000;
    final targetBarMeters = metersAcross * 0.22;
    final barMeters = _pickNiceDistance(targetBarMeters);
    final barPx = barMeters / metersAcross * size.width;
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
      text: TextSpan(
        text: _formatDistanceLabel(barMeters),
        style: const TextStyle(color: Colors.white70, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    scaleTp.paint(canvas, Offset(barX + barPx / 2 - scaleTp.width / 2, barY + 6));

    // Peer dots â€” coloured by triage status
    for (final peer in peers) {
      final pos = _toCanvas(size, peer.latitude, peer.longitude);
      if (pos.dx < -30 ||
          pos.dx > size.width + 30 ||
          pos.dy < -30 ||
          pos.dy > size.height + 30) {
        continue;
      }
      final isAlert = peer.triageStatus == TriageStatus.sos || peer.isSOS;
      final dotColor = peer.triageStatus.color;
      final pulseR = isAlert ? 10.0 + pulseValue * 18.0 : 0.0;
      final distText = _formatDistanceLabel(_distanceMetersToPeer(peer));

      final centerPoint = Offset(size.width / 2, size.height / 2);
      canvas.drawLine(
        centerPoint,
        pos,
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1,
      );

      _drawDot(
        canvas: canvas,
        center: pos,
        color: dotColor,
        radius: 8,
        label: '${peer.userName}\n$distText',
        pulseRadius: pulseR,
        pulseColor: TriageStatus.sos.color,
      );
    }

    // My arrow (always on center, rotates with heading)
    _drawArrow(
      canvas: canvas,
      center: Offset(size.width / 2, size.height / 2),
      headingDeg: heading,
    );

    // Compass rose (top-left) â€” needle points to true north
    final compassCenter = const Offset(36, 48);
    _drawCompassRose(canvas, compassCenter, heading);
  }

  @override
  bool shouldRepaint(_MeshMapPainter old) =>
      old.pulseValue != pulseValue ||
      old.peers.length != peers.length ||
      old.myLocation.latitude != myLocation.latitude ||
      old.heading != heading ||
      old.myTriageStatus != myTriageStatus ||
      old.zoom != zoom;

  double _pickNiceDistance(double meters) {
    if (meters <= 0) return 10;
    const nice = [
      5.0,
      10.0,
      20.0,
      50.0,
      100.0,
      200.0,
      500.0,
      1000.0,
      2000.0,
      5000.0,
    ];
    for (final v in nice) {
      if (v >= meters) return v;
    }
    return nice.last;
  }

  String _formatDistanceLabel(double meters) {
    if (meters >= 1000) {
      final km = meters / 1000;
      return km % 1 == 0 ? '${km.toStringAsFixed(0)} km' : '${km.toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

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
      Paint()..color = Colors.blueAccent.withValues(alpha: 0.15),
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
      Paint()..color = Colors.white.withValues(alpha: 0.12),
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
  }
}

// â”€â”€â”€ Triage colour legend â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _TriageLegend extends StatelessWidget {
  const _TriageLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: TriageStatus.values.map((s) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: s.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  s.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _NearbyDistancePanel extends StatelessWidget {
  final LocationUpdate? myLocation;
  final List<LocationUpdate> peers;

  const _NearbyDistancePanel({
    required this.myLocation,
    required this.peers,
  });

  @override
  Widget build(BuildContext context) {
    if (myLocation == null || peers.isEmpty) {
      return const SizedBox.shrink();
    }

    final nearest = [...peers]
      ..sort((a, b) => _distanceMeters(myLocation!, a).compareTo(_distanceMeters(myLocation!, b)));

    final show = nearest.take(4).toList();

    return Container(
      width: 170,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Nearest Survivors',
            style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          ...show.map((p) {
            final d = _distanceMeters(myLocation!, p);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${p.userName}: ${_distanceLabel(d)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.triageStatus.color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  static double _distanceMeters(LocationUpdate a, LocationUpdate b) {
    const earthRadius = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return earthRadius * c;
  }

  static String _distanceLabel(double meters) {
    if (meters >= 1000) {
      final km = meters / 1000;
      return km >= 10 ? '${km.toStringAsFixed(0)} km' : '${km.toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }
}

// ─── Navigate-to-survivor panel ───────────────────────────────────────────────

class _NavigatePanel extends StatelessWidget {
  final LocationUpdate peer;
  final LocationUpdate? myLocation;
  final VoidCallback onNavigate;
  final VoidCallback onDismiss;

  const _NavigatePanel({
    required this.peer,
    required this.myLocation,
    required this.onNavigate,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final color = peer.triageStatus.color;
    final dist = myLocation != null
        ? _NearbyDistancePanel._distanceMeters(myLocation!, peer)
        : 0.0;
    final distLabel = _NearbyDistancePanel._distanceLabel(dist);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xEE101828),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(peer.triageStatus.icon,
                color: peer.triageStatus.onColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  peer.userName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  '${peer.triageStatus.label} • $distLabel away',
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: onNavigate,
            icon: const Icon(Icons.navigation_rounded, size: 18),
            label: const Text('Navigate'),
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: peer.triageStatus.onColor,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onDismiss,
            child: const Icon(Icons.close, color: Colors.white38, size: 20),
          ),
        ],
      ),
    );
  }
}
