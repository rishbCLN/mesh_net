import 'dart:collection';
import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/danger_zone.dart';

/// Offline A* pathfinding that avoids danger zones.
class MapRoutingService {
  /// Default danger zone avoidance radius (meters).
  /// Adds a safety buffer around each danger zone.
  static const double _safetyBufferMeters = 30.0;

  /// Grid cell size in meters — controls path resolution vs performance.
  static const double _cellSizeMeters = 15.0;

  /// Computes a path from [start] to [end] that avoids [dangerZones].
  /// Returns a list of LatLng waypoints, or null if no path found.
  static List<LatLng>? findRoute({
    required LatLng start,
    required LatLng end,
    required List<DangerZone> dangerZones,
  }) {
    // Bounding box with padding
    final minLat = min(start.latitude, end.latitude) - 0.003;
    final maxLat = max(start.latitude, end.latitude) + 0.003;
    final minLng = min(start.longitude, end.longitude) - 0.003;
    final maxLng = max(start.longitude, end.longitude) + 0.003;

    // Convert cell size to approximate degrees
    // 1 degree latitude ≈ 111,320 meters
    final latStep = _cellSizeMeters / 111320.0;
    final midLat = (minLat + maxLat) / 2.0;
    final lngStep = _cellSizeMeters / (111320.0 * cos(midLat * pi / 180.0));

    final rows = ((maxLat - minLat) / latStep).ceil() + 1;
    final cols = ((maxLng - minLng) / lngStep).ceil() + 1;

    // Safety: cap grid size to prevent memory explosion
    if (rows * cols > 100000) return null;

    // Map LatLng → grid cell
    int toRow(double lat) => ((lat - minLat) / latStep).round().clamp(0, rows - 1);
    int toCol(double lng) => ((lng - minLng) / lngStep).round().clamp(0, cols - 1);
    LatLng toLatLng(int r, int c) => LatLng(minLat + r * latStep, minLng + c * lngStep);
    int cellId(int r, int c) => r * cols + c;

    // Build blocked-cell set
    final blocked = <int>{};
    for (final zone in dangerZones) {
      final zoneRadius = 50.0 + _safetyBufferMeters; // fixed avoidance radius
      // Determine bounding box in grid coords
      final latRange = zoneRadius / 111320.0;
      final lngRange = zoneRadius / (111320.0 * cos(zone.latitude * pi / 180.0));
      final r0 = toRow(zone.latitude - latRange);
      final r1 = toRow(zone.latitude + latRange);
      final c0 = toCol(zone.longitude - lngRange);
      final c1 = toCol(zone.longitude + lngRange);
      for (var r = r0; r <= r1; r++) {
        for (var c = c0; c <= c1; c++) {
          final cell = toLatLng(r, c);
          if (_haversineMeters(cell.latitude, cell.longitude,
                  zone.latitude, zone.longitude) <=
              zoneRadius) {
            blocked.add(cellId(r, c));
          }
        }
      }
    }

    // A* search
    final startR = toRow(start.latitude);
    final startC = toCol(start.longitude);
    final endR = toRow(end.latitude);
    final endC = toCol(end.longitude);

    // Don't block start/end cells
    blocked.remove(cellId(startR, startC));
    blocked.remove(cellId(endR, endC));

    final startId = cellId(startR, startC);
    final endId = cellId(endR, endC);

    // Heuristic: Euclidean grid distance
    double h(int r, int c) {
      final dr = (r - endR).toDouble();
      final dc = (c - endC).toDouble();
      return sqrt(dr * dr + dc * dc);
    }

    // Priority queue: (f-score, cellId)
    final openSet = SplayTreeMap<double, List<int>>();
    void addToOpen(double f, int id) {
      openSet.putIfAbsent(f, () => []).add(id);
    }

    final gScore = <int, double>{};
    final cameFrom = <int, int>{};
    final inOpen = <int>{};

    gScore[startId] = 0.0;
    addToOpen(h(startR, startC), startId);
    inOpen.add(startId);

    // 8-directional neighbors
    const dirs = [
      [-1, -1], [-1, 0], [-1, 1],
      [0, -1],           [0, 1],
      [1, -1],  [1, 0],  [1, 1],
    ];
    const sqrt2 = 1.41421356;

    while (openSet.isNotEmpty) {
      final firstKey = openSet.firstKey()!;
      final list = openSet[firstKey]!;
      final currentId = list.removeLast();
      if (list.isEmpty) openSet.remove(firstKey);
      inOpen.remove(currentId);

      if (currentId == endId) {
        // Reconstruct path
        final path = <LatLng>[end];
        var cur = endId;
        while (cameFrom.containsKey(cur)) {
          cur = cameFrom[cur]!;
          final r = cur ~/ cols;
          final c = cur % cols;
          path.add(toLatLng(r, c));
        }
        path.add(start);
        return _smoothPath(path.reversed.toList());
      }

      final curR = currentId ~/ cols;
      final curC = currentId % cols;
      final curG = gScore[currentId] ?? double.infinity;

      for (final d in dirs) {
        final nr = curR + d[0];
        final nc = curC + d[1];
        if (nr < 0 || nr >= rows || nc < 0 || nc >= cols) continue;
        final nId = cellId(nr, nc);
        if (blocked.contains(nId)) continue;

        final moveCost = (d[0] != 0 && d[1] != 0) ? sqrt2 : 1.0;
        final tentG = curG + moveCost;
        final prevG = gScore[nId] ?? double.infinity;

        if (tentG < prevG) {
          cameFrom[nId] = currentId;
          gScore[nId] = tentG;
          final f = tentG + h(nr, nc);
          if (!inOpen.contains(nId)) {
            addToOpen(f, nId);
            inOpen.add(nId);
          }
        }
      }
    }

    // No path found — return direct line as fallback
    return [start, end];
  }

  /// Simplify path by removing colinear intermediate points.
  static List<LatLng> _smoothPath(List<LatLng> path) {
    if (path.length <= 2) return path;
    final result = <LatLng>[path.first];
    for (var i = 1; i < path.length - 1; i++) {
      final prev = result.last;
      final curr = path[i];
      final next = path[i + 1];
      // Keep point if direction changes significantly
      final bearing1 = atan2(curr.longitude - prev.longitude, curr.latitude - prev.latitude);
      final bearing2 = atan2(next.longitude - curr.longitude, next.latitude - curr.latitude);
      if ((bearing1 - bearing2).abs() > 0.15) {
        result.add(curr);
      }
    }
    result.add(path.last);
    return result;
  }

  static double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLng = (lng2 - lng1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) *
        sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }
}
