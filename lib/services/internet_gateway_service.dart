import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/triage_status.dart';
import 'storage_service.dart';
import 'nearby_service.dart';

class InternetGatewayService {
  final StorageService _storage;
  final NearbyService _nearby;

  StreamSubscription<ConnectivityResult>? _connectivitySub;
  bool _uploadInProgress = false;
  bool _uploadSuccess = false;
  bool get uploadSuccess => _uploadSuccess;
  DateTime? _lastUpload;
  DateTime? get lastUpload => _lastUpload;

  // Backend endpoint — configurable in settings
  String gatewayUrl = '';
  static const Duration uploadCooldown = Duration(minutes: 5);

  InternetGatewayService({
    required StorageService storage,
    required NearbyService nearby,
  })  : _storage = storage,
        _nearby = nearby;

  void startMonitoring() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChange);
  }

  Future<void> _onConnectivityChange(ConnectivityResult result) async {
    final hasInternet =
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.ethernet;

    if (!hasInternet) return;
    if (_uploadInProgress) return;
    if (_lastUpload != null &&
        DateTime.now().difference(_lastUpload!) < uploadCooldown) return;

    await _performGatewayUpload();
  }

  Future<void> _performGatewayUpload() async {
    if (gatewayUrl.isEmpty) return;
    _uploadInProgress = true;

    try {
      final payload = await _buildGatewayPayload();

      final response = await http
          .post(
            Uri.parse(gatewayUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        _lastUpload = DateTime.now();
        _uploadSuccess = true;
        debugPrint('[INTERNET_GATEWAY] Upload succeeded');

        // Broadcast success to mesh so other nodes know data got out
        await _nearby.broadcastMessage(
          'GATEWAY::upload_success:${DateTime.now().toIso8601String()}',
        );
      }
    } catch (e) {
      // Silently fail — connection may have dropped mid-upload
      debugPrint('[INTERNET_GATEWAY] Upload failed: $e');
    } finally {
      _uploadInProgress = false;
    }
  }

  Future<Map<String, dynamic>> _buildGatewayPayload() async {
    final allMessages = await _storage.getAllMessages();
    final sosMessages = allMessages
        .where((m) => m.isSOS)
        .map((m) => m.toMap())
        .toList();

    final survivorList = <Map<String, dynamic>>[];
    for (final entry in _nearby.peerLocations.entries) {
      survivorList.add({
        'peerId': entry.key,
        'latitude': entry.value.latitude,
        'longitude': entry.value.longitude,
        'triage': entry.value.triageStatus.jsonValue,
        'lastSeen': entry.value.timestamp.toIso8601String(),
      });
    }

    int critical = 0, injured = 0, trapped = 0;
    for (final loc in _nearby.peerLocations.values) {
      switch (loc.triageStatus) {
        case TriageStatus.critical:
          critical++;
          break;
        case TriageStatus.injured:
          injured++;
          break;
        case TriageStatus.sos:
          trapped++;
          break;
        case TriageStatus.ok:
          break;
      }
    }

    return {
      'event': 'mesh_distress_upload',
      'uploadedAt': DateTime.now().toIso8601String(),
      'uploadedByDevice': _nearby.myEndpointId,
      'meshSize': _nearby.connectedDevices.length + 1,
      'sosMessages': sosMessages,
      'survivorMap': survivorList,
      'meshStats': {
        'totalMessages': allMessages.length,
        'critical': critical,
        'injured': injured,
        'trapped': trapped,
      },
    };
  }

  /// Force upload attempt — called manually or from Hard SOS Mode
  Future<bool> forceUpload() async {
    _lastUpload = null;
    await _performGatewayUpload();
    return _lastUpload != null;
  }

  void dispose() {
    _connectivitySub?.cancel();
  }
}
