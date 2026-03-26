import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/danger_zone.dart';
import '../models/location_update.dart';
import '../models/triage_status.dart';
import '../map/mbtiles_tile_provider.dart';
import '../map/cached_tile_provider.dart';
import '../map/building_label_layer.dart';
import '../services/danger_zone_service.dart';
import '../services/nearby_service.dart';
import 'navigate_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  late final MBTilesTileProvider _tileProvider;
  CachedNetworkTileProvider? _fallbackProvider;
  bool _tileProviderReady = false;
  bool _isAcquiring = false;
  String? _locationError;
  Timer? _refreshTimer;
  double _currentZoom = 16.0;
  LatLng _mapCenterDisplay = const LatLng(kVitLat, kVitLng);

  // VIT Vellore campus default center
  static const double kVitLat = 12.9692;
  static const double kVitLng = 79.1559;

  // Last-known location restored from SharedPreferences
  LatLng? _savedLocation;

  // Auto-follow: map center tracks self when true; panning disables it
  bool _followLocation = true;

  // Used to detect when location changes so we auto-move
  LocationUpdate? _prevMyLoc;

  @override
  void initState() {
    super.initState();
    _initTileProvider();
    _loadSavedLocation();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _acquireLocation();
      // Listen to NearbyService so map auto-follows GPS updates
      final service = Provider.of<NearbyService>(context, listen: false);
      service.addListener(_onServiceLocationUpdate);
    });
  }

  /// Load last-known GPS from SharedPreferences and use as initial map center.
  Future<void> _loadSavedLocation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble('lastLat');
      final lng = prefs.getDouble('lastLng');
      if (lat != null && lng != null && (lat != 0.0 || lng != 0.0)) {
        if (mounted) {
          setState(() {
            _savedLocation = LatLng(lat, lng);
            _mapCenterDisplay = LatLng(lat, lng);
          });
          // Move map to last known position as soon as controller is ready
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              try {
                _mapController.move(LatLng(lat, lng), _currentZoom);
              } catch (_) {}
            }
          });
        }
      }
    } catch (_) {}
  }

  /// Called every time NearbyService notifies — moves map if following.
  void _onServiceLocationUpdate() {
    if (!mounted) return;
    final service = Provider.of<NearbyService>(context, listen: false);
    final loc = service.myLocation;
    if (loc == null) return;
    if (loc.latitude == 0.0 && loc.longitude == 0.0) return;
    // Detect first real fix or movement
    if (_prevMyLoc?.latitude == loc.latitude &&
        _prevMyLoc?.longitude == loc.longitude) return;
    _prevMyLoc = loc;
    // Prefetch surrounding tiles once on first valid GPS fix
    if (_savedLocation == null && _fallbackProvider != null) {
      _prefetchSurroundingTiles(loc.latitude, loc.longitude);
    }
    // Move map if user hasn't manually panned away
    if (_followLocation) {
      try {
        _mapController.move(LatLng(loc.latitude, loc.longitude), _currentZoom);
      } catch (_) {}
    }
    setState(() {
      _mapCenterDisplay = LatLng(loc.latitude, loc.longitude);
    });
  }

  /// Download and cache all tiles in a ~1.5 km radius around [lat,lng]
  /// for zoom levels 14-17.  Runs in background — errors silently ignored.
  void _prefetchSurroundingTiles(double lat, double lng) {
    if (_fallbackProvider == null) return;
    CachedNetworkTileProvider.prefetchArea(
      lat: lat,
      lng: lng,
      radiusKm: 1.5,
      minZoom: 14,
      maxZoom: 17,
      cacheDir: _fallbackProvider!.cacheDir,
    );
  }

  /// Asynchronously initializes MBTiles + fallback tile providers.
  Future<void> _initTileProvider() async {
    _tileProvider = MBTilesTileProvider();
    await _tileProvider.initialize();
    final fb = CachedNetworkTileProvider();
    await fb.initialize();
    if (mounted) {
      setState(() {
        _fallbackProvider = fb;
        _tileProviderReady = true;
      });
    } else {
      _fallbackProvider = fb;
      _tileProviderReady = true;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    // Remove NearbyService listener
    final service =
        Provider.of<NearbyService>(context, listen: false);
    service.removeListener(_onServiceLocationUpdate);
    _tileProvider.dispose();
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
          if (service.myLocation == null) {
            _locationError = 'Could not get GPS fix.';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isAcquiring = false;
          _locationError = 'Location error. Tap retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<NearbyService>(context);
    final dangerService = Provider.of<DangerZoneService>(context);
    final myLoc = service.myLocation;
    final peers = service.peerLocations.values.toList();
    final zones = dangerService.zones.values.toList();

    final survivorCount = peers.length + (myLoc != null ? 1 : 0);
    final sosCount = peers.where((p) =>
        p.triageStatus == TriageStatus.sos || p.isSOS).length;

    if (!_tileProviderReady) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D1A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF00FF88)),
              SizedBox(height: 16),
              Text('Loading offline maps…',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
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
                  '$survivorCount survivor${survivorCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
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
                if (zones.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  const Icon(Icons.warning_amber, size: 14, color: Colors.yellow),
                  const SizedBox(width: 4),
                  Text(
                    '${zones.length} hazard${zones.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.yellow, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      body: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _mapCenter(myLoc),
                    initialZoom: 16.0,
                    minZoom: 14.0,
                    maxZoom: 18.0,
                    onLongPress: (tapPos, point) =>
                        _onLongPress(context, point, service, dangerService),
                    onMapEvent: (event) {
                      if (event is MapEventMoveStart &&
                          event.source != MapEventSource.mapController) {
                        // User panned manually — stop auto-follow
                        _followLocation = false;
                      }
                      if (event is MapEventMove) {
                        setState(() {
                          _currentZoom = event.camera.zoom;
                          _mapCenterDisplay = event.camera.center;
                        });
                      }
                    },
                  ),
                  children: [
                    // Layer 1: Tiles — MBTiles (fully offline) or cached network
                    ColorFiltered(
                      colorFilter: const ColorFilter.matrix(<double>[
                        1.2, 0,   0,   0, -20,
                        0,   1.2, 0,   0, -20,
                        0,   0,   1.1, 0, -10,
                        0,   0,   0,   1,  0,
                      ]),
                      child: TileLayer(
                        tileProvider: _tileProvider.isAvailable
                            ? _tileProvider
                            : (_fallbackProvider ?? _tileProvider),
                        errorTileCallback: (tile, error, stackTrace) {},
                      ),
                    ),

                    // Layer 2: Mesh edges — only when GPS fix is available
                    if (myLoc != null)
                      PolylineLayer(
                        polylines: _buildMeshEdges(myLoc, peers),
                      ),

                    // Layer 3: Building labels — only at zoom >= 15
                    if (_currentZoom >= 15)
                      const BuildingLabelLayer(),

                    // Layer 4: Survivor markers — only when GPS fix is available
                    if (myLoc != null)
                      MarkerLayer(
                        markers: _buildSurvivorMarkers(myLoc, peers),
                      ),

                    // Layer 5: Danger zone markers
                    MarkerLayer(
                      markers: _buildDangerMarkers(zones),
                    ),
                  ],
                ),

                // ── Tile source chip (top-right) ──────────────────────────
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _tileProvider.isAvailable
                              ? Icons.offline_bolt
                              : Icons.wifi_rounded,
                          size: 11,
                          color: _tileProvider.isAvailable
                              ? const Color(0xFF00FF88)
                              : Colors.blue,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _tileProvider.isAvailable ? 'MBTiles' : 'Online',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── GPS status chip — shown when no fix yet ──────────────
                if (myLoc == null || _isAcquiring)
                  Positioned(
                    bottom: 136,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.6)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isAcquiring)
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5, color: Colors.orange),
                            )
                          else
                            const Icon(Icons.location_off,
                                size: 12, color: Colors.orange),
                          const SizedBox(width: 6),
                          Text(
                            _isAcquiring
                                ? 'Getting GPS…'
                                : (_locationError ?? 'No GPS fix'),
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 11),
                          ),
                          if (!_isAcquiring) ...[  
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: _acquireLocation,
                              child: const Text('Retry',
                                  style: TextStyle(
                                      color: Colors.orange,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      decoration:
                                          TextDecoration.underline)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                // Legend (top-left)
                Positioned(
                  top: 12,
                  left: 12,
                  child: _buildLegend(zones.isNotEmpty),
                ),

                // Coordinates display (bottom-left) — updates as map pans
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: _CoordinatesOverlay(
                    center: _mapCenterDisplay,
                    myLoc: myLoc,
                    distanceM: Provider.of<NearbyService>(context,
                            listen: false)
                        .totalDistanceTraveled,
                  ),
                ),

                // Recenter / follow-me FAB
                Positioned(
                  bottom: 24,
                  right: 16,
                  child: FloatingActionButton.small(
                    backgroundColor: _followLocation
                        ? const Color(0xFF00FF88)
                        : const Color(0xFF1A1A2E),
                    onPressed: () {
                      setState(() => _followLocation = true);
                      final loc = Provider.of<NearbyService>(context,
                              listen: false)
                          .myLocation;
                      if (loc != null &&
                          (loc.latitude != 0.0 || loc.longitude != 0.0)) {
                        _mapController.move(
                            LatLng(loc.latitude, loc.longitude),
                            _currentZoom);
                      }
                    },
                    child: Icon(
                      Icons.my_location,
                      color: _followLocation
                          ? const Color(0xFF0D0D1A)
                          : const Color(0xFF00FF88),
                    ),
                  ),
                ),

                // Refresh location FAB
                Positioned(
                  bottom: 80,
                  right: 16,
                  child: FloatingActionButton.small(
                    backgroundColor: Colors.orange,
                    onPressed: _isAcquiring ? null : _acquireLocation,
                    child: _isAcquiring
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.refresh, color: Colors.white),
                  ),
                ),
              ],
            ),
    );
  }

  /// Returns the map center: saved GPS > current GPS > VIT default.
  LatLng _mapCenter(LocationUpdate? loc) {
    if (loc != null && (loc.latitude != 0.0 || loc.longitude != 0.0)) {
      return LatLng(loc.latitude, loc.longitude);
    }
    if (_savedLocation != null) return _savedLocation!;
    return const LatLng(kVitLat, kVitLng);
  }

  // ─── Mesh Edge Lines ────────────────────────────────────────────────────────

  List<Polyline> _buildMeshEdges(
    LocationUpdate myLoc,
    List<LocationUpdate> peers,
  ) {
    final ownPoint = LatLng(myLoc.latitude, myLoc.longitude);
    return peers.map((peer) {
      return Polyline(
        points: [ownPoint, LatLng(peer.latitude, peer.longitude)],
        color: const Color(0xFF00FF88).withValues(alpha: 0.3),
        strokeWidth: 1.5,
        isDotted: true,
      );
    }).toList();
  }

  // ─── Survivor Markers ──────────────────────────────────────────────────────

  List<Marker> _buildSurvivorMarkers(
    LocationUpdate myLoc,
    List<LocationUpdate> peers,
  ) {
    final markers = <Marker>[];

    // Self — directional arrow colored by own triage status
    final selfColor = myLoc.triageStatus.color;
    markers.add(Marker(
      point: LatLng(myLoc.latitude, myLoc.longitude),
      width: 64,
      height: 72,
      child: _DirectionalMarker(
        color: selfColor,
        heading: myLoc.heading,
        label: 'You',
        icon: myLoc.triageStatus.icon,
        isSelf: true,
      ),
    ));

    // Peers — directional arrow colored by triage status
    for (final peer in peers) {
      final color = peer.triageStatus.color;
      markers.add(Marker(
        point: LatLng(peer.latitude, peer.longitude),
        width: 80,
        height: 72,
        child: GestureDetector(
          onTap: () => _showSurvivorDetail(peer),
          child: _DirectionalMarker(
            color: color,
            heading: peer.heading,
            label: peer.userName,
            icon: peer.triageStatus.icon,
            isSelf: false,
          ),
        ),
      ));
    }

    return markers;
  }

  // ─── Danger Zone Markers ───────────────────────────────────────────────────

  List<Marker> _buildDangerMarkers(List<DangerZone> zones) {
    return zones.map((zone) {
      return Marker(
        point: LatLng(zone.latitude, zone.longitude),
        width: 64,
        height: 64,
        child: GestureDetector(
          onTap: () => _showDangerZoneDetail(zone),
          child: _DangerZoneMarker(zone: zone),
        ),
      );
    }).toList();
  }

  // ─── Long Press → Add Danger Zone ─────────────────────────────────────────

  void _onLongPress(
    BuildContext context,
    LatLng point,
    NearbyService service,
    DangerZoneService dangerService,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AddDangerZoneSheet(
        location: point,
        onSubmit: (type, description, imageBytes) async {
          final broadcast = await dangerService.createDangerZone(
            reportedBy: service.myEndpointId,
            reportedByName: service.userName,
            latitude: point.latitude,
            longitude: point.longitude,
            type: type,
            description: description,
            imageBytes: imageBytes,
          );
          await service.broadcastDangerZone(broadcast);
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  // ─── Detail Sheets ────────────────────────────────────────────────────────

  void _showSurvivorDetail(LocationUpdate peer) {
    final service = Provider.of<NearbyService>(context, listen: false);
    final myLoc = service.myLocation;
    final dist = myLoc != null ? _distanceMeters(myLoc, peer) : 0.0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: peer.triageStatus.color,
                shape: BoxShape.circle,
              ),
              child: Icon(peer.triageStatus.icon,
                  color: peer.triageStatus.onColor, size: 24),
            ),
            const SizedBox(height: 12),
            Text(peer.userName,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '${peer.triageStatus.label} • ${_distanceLabel(dist)} away',
              style: TextStyle(color: peer.triageStatus.color, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              '${peer.latitude.toStringAsFixed(6)}, ${peer.longitude.toStringAsFixed(6)}',
              style: const TextStyle(
                  color: Color(0xFF00FF88),
                  fontSize: 12,
                  fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NavigateScreen(target: peer),
                  ),
                );
              },
              icon: const Icon(Icons.navigation_rounded),
              label: const Text('Navigate'),
              style: ElevatedButton.styleFrom(
                backgroundColor: peer.triageStatus.color,
                foregroundColor: peer.triageStatus.onColor,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showDangerZoneDetail(DangerZone zone) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DangerZoneDetailSheet(zone: zone),
    );
  }

  // ─── Legend ────────────────────────────────────────────────────────────────

  Widget _buildLegend(bool hasDanger) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _legendItem(const Color(0xFF00FF88), 'You'),
          ...TriageStatus.values.map(
            (s) => _legendItem(s.color, s.label),
          ),
          if (hasDanger)
            _legendItem(Colors.yellow, '⚠ Danger Zone'),
          _legendItem(Colors.white38, 'Long press = pin hazard'),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      );

  // ─── Helpers ──────────────────────────────────────────────────────────────

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
      return km >= 10
          ? '${km.toStringAsFixed(0)} km'
          : '${km.toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }
}

// ─── Directional Marker Widget ──────────────────────────────────────────────
//
// A directional arrow that rotates to show heading, colored by triage status.
// For self: shows a larger pulsing arrow. For peers: a smaller static arrow.

class _DirectionalMarker extends StatefulWidget {
  final Color color;
  final double heading; // degrees from north (0..360)
  final String label;
  final IconData icon;
  final bool isSelf;

  const _DirectionalMarker({
    required this.color,
    required this.heading,
    required this.label,
    required this.icon,
    required this.isSelf,
  });

  @override
  State<_DirectionalMarker> createState() => _DirectionalMarkerState();
}

class _DirectionalMarkerState extends State<_DirectionalMarker>
    with SingleTickerProviderStateMixin {
  AnimationController? _pulseCtrl;

  @override
  void initState() {
    super.initState();
    if (widget.isSelf) {
      _pulseCtrl = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulseCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headingRad = widget.heading * 3.14159265 / 180.0;
    final arrowSize = widget.isSelf ? 36.0 : 28.0;

    Widget arrow = Transform.rotate(
      angle: headingRad,
      child: CustomPaint(
        size: Size(arrowSize, arrowSize),
        painter: _ArrowPainter(
          color: widget.color,
          borderColor: Colors.white,
        ),
      ),
    );

    // Pulse ring for self
    if (widget.isSelf && _pulseCtrl != null) {
      arrow = AnimatedBuilder(
        animation: _pulseCtrl!,
        builder: (_, __) {
          final pulse = _pulseCtrl!.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: arrowSize + 12 + pulse * 10,
                height: arrowSize + 12 + pulse * 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.color.withValues(alpha: 0.3 - pulse * 0.25),
                    width: 2,
                  ),
                ),
              ),
              Transform.rotate(
                angle: headingRad,
                child: CustomPaint(
                  size: Size(arrowSize, arrowSize),
                  painter: _ArrowPainter(
                    color: widget.color,
                    borderColor: Colors.white,
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: arrowSize + 24,
          height: arrowSize + 24,
          child: Center(child: arrow),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(blurRadius: 3, color: Colors.black)],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  _ArrowPainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Arrow pointing UP (north) — Triangle with notched tail
    final path = ui.Path()
      ..moveTo(w * 0.5, 0) // tip (north)
      ..lineTo(w * 0.85, h * 0.75) // right wing
      ..lineTo(w * 0.5, h * 0.55) // notch center
      ..lineTo(w * 0.15, h * 0.75) // left wing
      ..close();

    // White border
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Filled arrow
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) =>
      color != oldDelegate.color || borderColor != oldDelegate.borderColor;
}

// ─── Danger Zone Marker Widget ──────────────────────────────────────────────

class _DangerZoneMarker extends StatelessWidget {
  final DangerZone zone;
  const _DangerZoneMarker({required this.zone});

  Color get _dangerColor {
    switch (zone.type) {
      case DangerType.fire:
        return Colors.deepOrange;
      case DangerType.flood:
        return Colors.blue;
      case DangerType.collapse:
        return Colors.grey;
      case DangerType.gas:
        return Colors.yellow;
      case DangerType.electrical:
        return Colors.amber;
      case DangerType.blocked:
        return Colors.brown;
      case DangerType.other:
        return Colors.red;
    }
  }

  IconData get _dangerIcon {
    switch (zone.type) {
      case DangerType.fire:
        return Icons.local_fire_department;
      case DangerType.flood:
        return Icons.water;
      case DangerType.collapse:
        return Icons.domain_disabled;
      case DangerType.gas:
        return Icons.air;
      case DangerType.electrical:
        return Icons.bolt;
      case DangerType.blocked:
        return Icons.block;
      case DangerType.other:
        return Icons.warning_amber;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer ring
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _dangerColor, width: 3),
            boxShadow: [
              BoxShadow(
                color: _dangerColor.withValues(alpha: 0.4),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
        ),

        // Inner: photo thumbnail or icon fallback
        ClipOval(
          child: zone.imageReceived && zone.imageBytes != null
              ? Image.memory(
                  zone.imageBytes!,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                )
              : Container(
                  width: 56,
                  height: 56,
                  color: const Color(0xFF1A1A2E),
                  child: Icon(_dangerIcon, color: _dangerColor, size: 28),
                ),
        ),

        // Loading spinner while chunks arrive
        if (zone.imageId != null && !zone.imageReceived)
          Positioned(
            bottom: 4,
            right: 4,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Danger Zone Detail Sheet ───────────────────────────────────────────────

class _DangerZoneDetailSheet extends StatelessWidget {
  final DangerZone zone;
  const _DangerZoneDetailSheet({required this.zone});

  Color get _dangerColor {
    switch (zone.type) {
      case DangerType.fire:
        return Colors.deepOrange;
      case DangerType.flood:
        return Colors.blue;
      default:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      maxChildSize: 0.9,
      minChildSize: 0.35,
      expand: false,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Full photo
            if (zone.imageReceived && zone.imageBytes != null)
              ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                child: Image.memory(
                  zone.imageBytes!,
                  width: double.infinity,
                  height: 240,
                  fit: BoxFit.cover,
                ),
              )
            else
              Container(
                height: 100,
                decoration: const BoxDecoration(
                  color: Color(0xFF0D0D1A),
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: const Center(
                  child: Text('No photo attached',
                      style: TextStyle(color: Colors.white38)),
                ),
              ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Type badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _dangerColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: _dangerColor.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      zone.type.label.toUpperCase(),
                      style: TextStyle(
                        color: _dangerColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  Text(
                    zone.description,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Reported by ${zone.reportedByName}',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  Text(
                    _formatTime(zone.timestamp),
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D0D1A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${zone.latitude.toStringAsFixed(6)}, ${zone.longitude.toStringAsFixed(6)}',
                      style: const TextStyle(
                        color: Color(0xFF00FF88),
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),

                  if (zone.imageId != null && !zone.imageReceived)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white38),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Photo receiving over mesh…',
                            style: TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

// ─── Add Danger Zone Sheet ──────────────────────────────────────────────────

class _AddDangerZoneSheet extends StatefulWidget {
  final LatLng location;
  final Future<void> Function(DangerType, String, Uint8List?) onSubmit;
  const _AddDangerZoneSheet({required this.location, required this.onSubmit});

  @override
  State<_AddDangerZoneSheet> createState() => _AddDangerZoneSheetState();
}

class _AddDangerZoneSheetState extends State<_AddDangerZoneSheet> {
  DangerType _selectedType = DangerType.collapse;
  final _descController = TextEditingController();
  Uint8List? _imageBytes;
  bool _submitting = false;

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final result = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 60,
      maxWidth: 800,
    );
    if (result != null) {
      final bytes = await result.readAsBytes();
      setState(() => _imageBytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.yellow, size: 24),
              const SizedBox(width: 8),
              const Text('Mark Danger Zone',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.location.latitude.toStringAsFixed(5)}, ${widget.location.longitude.toStringAsFixed(5)}',
            style: const TextStyle(
                color: Color(0xFF00FF88), fontSize: 11, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 16),

          // Type selector
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: DangerType.values.map((type) {
              final selected = _selectedType == type;
              return GestureDetector(
                onTap: () => setState(() => _selectedType = type),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.red.withValues(alpha: 0.2)
                        : const Color(0xFF0D0D1A),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected ? Colors.red : Colors.white24,
                    ),
                  ),
                  child: Text(
                    type.label.toUpperCase(),
                    style: TextStyle(
                      color: selected ? Colors.red : Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // Description
          TextField(
            controller: _descController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Describe the hazard…',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF0D0D1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.white24),
              ),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),

          // Photo
          Row(
            children: [
              GestureDetector(
                onTap: _pickImage,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D1A),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: _imageBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(_imageBytes!,
                              fit: BoxFit.cover),
                        )
                      : const Icon(Icons.add_a_photo,
                          color: Colors.white38, size: 28),
                ),
              ),
              const SizedBox(width: 12),
              const Text('Photograph the hazard\n(optional)',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 16),

          // Submit
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.cell_tower),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _submitting
                  ? null
                  : () async {
                      if (_descController.text.isEmpty) return;
                      setState(() => _submitting = true);
                      await widget.onSubmit(
                        _selectedType,
                        _descController.text,
                        _imageBytes,
                      );
                    },
              label: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Broadcast Danger Zone',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Coordinates Overlay ────────────────────────────────────────────────────

class _CoordinatesOverlay extends StatelessWidget {
  final LatLng center;
  final LocationUpdate? myLoc;
  final double distanceM;

  const _CoordinatesOverlay({
    required this.center,
    required this.myLoc,
    required this.distanceM,
  });

  String _distLabel(double m) {
    if (m < 10) return '';
    if (m < 1000) return '  ${m.toStringAsFixed(0)} m moved';
    return '  ${(m / 1000).toStringAsFixed(2)} km moved';
  }

  @override
  Widget build(BuildContext context) {
    final hasGps = myLoc != null &&
        (myLoc!.latitude != 0.0 || myLoc!.longitude != 0.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xCC0D0D1A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${center.latitude.toStringAsFixed(5)}, ${center.longitude.toStringAsFixed(5)}',
            style: const TextStyle(
              color: Color(0xFF00FF88),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          if (hasGps) ...[
            const SizedBox(height: 2),
            Text(
              'GPS: ${myLoc!.latitude.toStringAsFixed(5)}, ${myLoc!.longitude.toStringAsFixed(5)}${_distLabel(distanceM)}',
              style: const TextStyle(
                color: Color(0xFF88CCFF),
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
