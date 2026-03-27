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

  
  static const String defaultBinUrl = 'https://api.jsonbin.io/v3/b/69c63d08aa77b81da924ff94';
  static const String defaultBinKey = r'$2a$10$H4E2tH4v/4D2UylYgZv/yewVYeBXNgTqedQ7v/eE/mx0OUWnzFOTO';

  
  String gatewayUrl = defaultBinUrl;
  String jsonBinApiKey = defaultBinKey;

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
    if (gatewayUrl.isEmpty || jsonBinApiKey.isEmpty) return;
    _uploadInProgress = true;

    try {
      final payload = await _buildPayload();

      
      final response = await http
          .put(
            Uri.parse(gatewayUrl),
            headers: {
              'Content-Type': 'application/json',
              'X-Master-Key': jsonBinApiKey,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        _lastUpload = DateTime.now();
        _uploadSuccess = true;
        debugPrint('[GATEWAY] JSONBin upload OK — ${payload['survivors']?.length ?? 0} survivors');

        
        await _nearby.broadcastMessage(
          'GATEWAY::upload_success:${DateTime.now().toIso8601String()}',
        );
      } else {
        debugPrint('[GATEWAY] JSONBin responded ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      debugPrint('[GATEWAY] Upload failed: $e');
    } finally {
      _uploadInProgress = false;
    }
  }

  
  
  Future<Map<String, dynamic>> _buildPayload() async {
    final allMessages = await _storage.getAllMessages();

    
    final survivors = <Map<String, dynamic>>[];

    
    if (_nearby.myLocation != null) {
      survivors.add({
        'name': _nearby.myEndpointId,
        'lat': _nearby.myLocation!.latitude,
        'lng': _nearby.myLocation!.longitude,
        'status': _triageToStatus(_nearby.myTriageStatus),
        'lastSeen': DateTime.now().toIso8601String(),
      });
    }

    
    for (final entry in _nearby.peerLocations.entries) {
      survivors.add({
        'name': entry.value.userName,
        'lat': entry.value.latitude,
        'lng': entry.value.longitude,
        'status': _triageToStatus(entry.value.triageStatus),
        'lastSeen': entry.value.timestamp.toIso8601String(),
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
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'survivors': survivors,
      'sosLog': sosLog,
      'uploadedBy': _nearby.myEndpointId,
      'meshSize': _nearby.connectedDevices.length + 1,
    };
  }

  static String _triageToStatus(TriageStatus triage) {
    switch (triage) {
      case TriageStatus.critical:
      case TriageStatus.sos:
        return 'critical';
      case TriageStatus.injured:
        return 'injured';
      case TriageStatus.ok:
        return 'ok';
    }
  }

  
  Future<bool> forceUpload() async {
    _lastUpload = null;
    await _performGatewayUpload();
    return _lastUpload != null;
  }

  void dispose() {
    _connectivitySub?.cancel();
  }
}
