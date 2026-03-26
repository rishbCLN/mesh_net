import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/danger_zone.dart';
import 'danger_image_service.dart';
import 'storage_service.dart';

/// Manages danger zones state — used as a ChangeNotifier via Provider.
class DangerZoneService extends ChangeNotifier {
  final StorageService _storage = StorageService();
  final Uuid _uuid = const Uuid();

  /// All known danger zones, keyed by zone id.
  final Map<String, DangerZone> zones = {};

  /// Pending image chunks: imageId → { chunkIndex → base64chunk }
  final Map<String, Map<int, String>> _pendingChunks = {};
  /// Expected total chunk count per imageId.
  final Map<String, int> _expectedChunks = {};

  /// Load persisted danger zones from SQLite.
  Future<void> loadFromStorage() async {
    final list = await _storage.getDangerZones();
    for (final z in list) {
      zones[z.id] = z;
    }
    notifyListeners();
  }

  /// Handle an incoming DANGER:: payload (metadata only, no prefix).
  void handleDangerPayload(String payload) {
    try {
      final zone = DangerZone.fromPayload(payload);
      if (zones.containsKey(zone.id)) return; // already known
      zones[zone.id] = zone;
      notifyListeners();
      _storage.saveDangerZone(zone);
    } catch (e) {
      debugPrint('[DANGER] Failed to parse danger zone: $e');
    }
  }

  /// Handle an incoming DIMG:: payload (image chunk, no prefix).
  /// Format: "{imageId}::{chunkIndex}::{totalChunks}::{base64data}"
  void handleImageChunk(String payload) {
    try {
      final parts = payload.split('::');
      if (parts.length < 4) return;

      final imageId = parts[0];
      final chunkIndex = int.parse(parts[1]);
      final totalChunks = int.parse(parts[2]);
      // Rejoin remaining parts — base64 data might contain '::' (unlikely but safe)
      final chunkData = parts.sublist(3).join('::');

      _pendingChunks.putIfAbsent(imageId, () => {});
      _pendingChunks[imageId]![chunkIndex] = chunkData;
      _expectedChunks[imageId] = totalChunks;

      // Try to reassemble
      final assembled = DangerImageService.reassembleChunks(
        totalChunks,
        _pendingChunks[imageId]!,
      );

      if (assembled != null) {
        // Find the zone that references this imageId
        final zone = zones.values.where((z) => z.imageId == imageId).firstOrNull;
        if (zone != null) {
          zone.imageBytes = assembled;
          zone.imageReceived = true;
          notifyListeners();
          _storage.saveDangerZone(zone);
        }
        _pendingChunks.remove(imageId);
        _expectedChunks.remove(imageId);
      }
    } catch (e) {
      debugPrint('[DANGER] Chunk processing error: $e');
    }
  }

  /// Create a new danger zone locally and return it + the mesh payloads to broadcast.
  /// The caller (NearbyService) handles the actual broadcasting.
  Future<DangerZoneBroadcast> createDangerZone({
    required String reportedBy,
    required String reportedByName,
    required double latitude,
    required double longitude,
    required DangerType type,
    required String description,
    Uint8List? imageBytes,
  }) async {
    final zoneId = _uuid.v4();
    String? imageId;
    List<String> imageChunkPayloads = [];

    if (imageBytes != null) {
      imageId = _uuid.v4();
      imageChunkPayloads = DangerImageService.chunkImage(imageId, imageBytes);
    }

    final zone = DangerZone(
      id: zoneId,
      reportedBy: reportedBy,
      reportedByName: reportedByName,
      latitude: latitude,
      longitude: longitude,
      type: type,
      description: description,
      timestamp: DateTime.now(),
      imageId: imageId,
      imageBytes: imageBytes,
      imageReceived: imageBytes != null,
    );

    zones[zoneId] = zone;
    notifyListeners();
    await _storage.saveDangerZone(zone);

    return DangerZoneBroadcast(
      metadataPayload: zone.toPayload(),
      imageChunkPayloads: imageChunkPayloads,
    );
  }
}

/// Holds the payloads that need to be broadcast over mesh.
class DangerZoneBroadcast {
  final String metadataPayload;
  final List<String> imageChunkPayloads;
  const DangerZoneBroadcast({
    required this.metadataPayload,
    required this.imageChunkPayloads,
  });
}
