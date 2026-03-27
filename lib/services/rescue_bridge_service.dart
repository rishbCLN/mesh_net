import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/triage_status.dart';
import 'storage_service.dart';
import 'nearby_service.dart';
import '../core/constants.dart';

enum DeviceRole {
  survivor,     
  coordinator,  
  rescue,       
}

class RescueBridgeService {
  final StorageService _storage;
  final NearbyService _nearby;

  int handoffsCompleted = 0;

  RescueBridgeService({
    required StorageService storage,
    required NearbyService nearby,
  })  : _storage = storage,
        _nearby = nearby;

  
  
  Future<void> onPeerConnected(String peerId, String peerName) async {
    final role = _parseRoleFromName(peerName);
    if (role == DeviceRole.rescue || role == DeviceRole.coordinator) {
      await _dumpCensusToDevice(peerId);
      handoffsCompleted++;
      debugPrint('[RESCUE_BRIDGE] Census dumped to $peerName ($role)');
    }
  }

  
  
  
  
  DeviceRole _parseRoleFromName(String name) {
    if (name.startsWith('RESCUE:')) return DeviceRole.rescue;
    if (name.startsWith('COORD:')) return DeviceRole.coordinator;
    return DeviceRole.survivor;
  }

  Future<void> _dumpCensusToDevice(String peerId) async {
    try {
      final census = await buildCensusReport();
      final payload = Constants.CENSUS_PREFIX + jsonEncode(census);
      final bytes = Uint8List.fromList(utf8.encode(payload));
      await _nearby.sendBytesToPeer(peerId, bytes);
    } catch (e) {
      debugPrint('[RESCUE_BRIDGE] Census dump failed: $e');
    }
  }

  Future<Map<String, dynamic>> buildCensusReport() async {
    final allMessages = await _storage.getAllMessages();

    final survivors = <Map<String, dynamic>>[];
    for (final entry in _nearby.peerLocations.entries) {
      survivors.add({
        'id': entry.key,
        'name': entry.value.userName,
        'lat': entry.value.latitude,
        'lng': entry.value.longitude,
        'triage': entry.value.triageStatus.jsonValue,
        'lastContact': entry.value.timestamp.toIso8601String(),
      });
    }

    final sosLog = allMessages
        .where((m) => m.isSOS)
        .map((m) => {
              'sender': m.senderName,
              'content': m.content.replaceFirst('SOS::', ''),
              'time': m.timestamp.toIso8601String(),
            })
        .toList();

    return {
      'reportType': 'survivor_census',
      'generatedAt': DateTime.now().toIso8601String(),
      'generatedBy': _nearby.myEndpointId,
      'summary': {
        'totalSurvivors': _nearby.connectedDevices.length + 1,
        'meshRadiusKm': _estimateMeshRadiusKm(),
      },
      'survivors': survivors,
      'sosLog': sosLog,
    };
  }

  double _estimateMeshRadiusKm() {
    final locations = _nearby.peerLocations.values.toList();
    if (locations.length < 2) return 0;
    double maxDist = 0;
    for (int i = 0; i < locations.length; i++) {
      for (int j = i + 1; j < locations.length; j++) {
        final d = _haversineKm(
          locations[i].latitude,
          locations[i].longitude,
          locations[j].latitude,
          locations[j].longitude,
        );
        if (d > maxDist) maxDist = d;
      }
    }
    return maxDist;
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _toRad(double deg) => deg * pi / 180;
}
