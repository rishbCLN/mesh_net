import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/danger_zone.dart';
import 'danger_image_service.dart';
import 'storage_service.dart';

class DangerZoneService extends ChangeNotifier {
  final StorageService _storage = StorageService();
  final Uuid _uuid = const Uuid();

  
  final Map<String, DangerZone> zones = {};

  
  final Map<String, Map<int, String>> _pendingChunks = {};
  
  final Map<String, int> _expectedChunks = {};

  
  Future<void> loadFromStorage() async {
    final list = await _storage.getDangerZones();
    for (final z in list) {
      zones[z.id] = z;
    }
    notifyListeners();
  }

  
  void handleDangerPayload(String payload) {
    try {
      final zone = DangerZone.fromPayload(payload);
      if (zones.containsKey(zone.id)) return; 
      zones[zone.id] = zone;
      notifyListeners();
      _storage.saveDangerZone(zone);
    } catch (e) {
      debugPrint('[DANGER] Failed to parse danger zone: $e');
    }
  }

  
  
  void handleImageChunk(String payload) {
    try {
      final parts = payload.split('::');
      if (parts.length < 4) return;

      final imageId = parts[0];
      final chunkIndex = int.parse(parts[1]);
      final totalChunks = int.parse(parts[2]);
      
      final chunkData = parts.sublist(3).join('::');

      _pendingChunks.putIfAbsent(imageId, () => {});
      _pendingChunks[imageId]![chunkIndex] = chunkData;
      _expectedChunks[imageId] = totalChunks;

      
      final assembled = DangerImageService.reassembleChunks(
        totalChunks,
        _pendingChunks[imageId]!,
      );

      if (assembled != null) {
        
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

class DangerZoneBroadcast {
  final String metadataPayload;
  final List<String> imageChunkPayloads;
  const DangerZoneBroadcast({
    required this.metadataPayload,
    required this.imageChunkPayloads,
  });
}
