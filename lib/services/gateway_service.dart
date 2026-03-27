import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sms_gateway_service.dart';
import 'internet_gateway_service.dart';
import 'rescue_bridge_service.dart';
import 'storage_service.dart';
import 'nearby_service.dart';

enum GatewayStatus {
  idle,          // Monitoring, no signal escaped yet
  attempting,    // SMS sending / upload in progress
  smsSent,       // SMS successfully sent
  internetUploaded, // Data uploaded to server
  rescueHandoff,   // Rescue team connected, census dumped
}

class GatewayService extends ChangeNotifier {
  final SmsGatewayService sms;
  final InternetGatewayService internet;
  final RescueBridgeService rescue;

  GatewayStatus _status = GatewayStatus.idle;
  GatewayStatus get status => _status;

  /// Human-readable log of gateway events
  final List<String> eventLog = [];

  GatewayService({
    required StorageService storage,
    required NearbyService nearby,
  })  : sms = SmsGatewayService(storage: storage, nearby: nearby),
        internet = InternetGatewayService(storage: storage, nearby: nearby),
        rescue = RescueBridgeService(storage: storage, nearby: nearby);

  /// Call once at app start — all layers begin passive monitoring.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final contacts = prefs.getStringList('emergency_contacts') ?? [];
    final url = prefs.getString('gateway_url') ?? '';

    sms.setEmergencyContacts(contacts);
    sms.startMonitoring();

    internet.gatewayUrl = url.isNotEmpty ? url : InternetGatewayService.defaultBinUrl;
    internet.jsonBinApiKey = prefs.getString('jsonbin_api_key')?.isNotEmpty == true
        ? prefs.getString('jsonbin_api_key')!
        : InternetGatewayService.defaultBinKey;
    internet.startMonitoring();

    // RescueBridge is event-driven — triggered by NearbyService peer events
    _addLog('Gateway monitoring started');
    notifyListeners();
  }

  /// Called when Hard SOS Mode activates — all layers attempt immediately.
  Future<void> hardSOSActivated() async {
    _status = GatewayStatus.attempting;
    _addLog('Hard SOS — firing all channels');
    notifyListeners();

    await Future.wait([
      sms.forceSend(),
      internet.forceUpload(),
    ]);

    // Update status based on results
    if (sms.smsSent) {
      _status = GatewayStatus.smsSent;
      _addLog('SMS distress sent');
    }
    if (internet.uploadSuccess) {
      _status = GatewayStatus.internetUploaded;
      _addLog('Internet upload succeeded');
    }
    if (!sms.smsSent && !internet.uploadSuccess) {
      _status = GatewayStatus.idle;
      _addLog('All channels failed — will retry');
    }
    notifyListeners();
  }

  /// Called by NearbyService on new peer connection.
  Future<void> onPeerConnected(String peerId, String peerName) async {
    await rescue.onPeerConnected(peerId, peerName);
    if (rescue.handoffsCompleted > 0) {
      _status = GatewayStatus.rescueHandoff;
      _addLog('Census handed off to $peerName');
      notifyListeners();
    }
  }

  /// Save emergency contacts to prefs and update SMS service.
  Future<void> saveEmergencyContacts(List<String> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('emergency_contacts', contacts);
    sms.setEmergencyContacts(contacts);
    notifyListeners();
  }

  /// Save gateway URL to prefs and update internet service.
  Future<void> saveGatewayUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gateway_url', url);
    internet.gatewayUrl = url;
    notifyListeners();
  }

  /// Save JSONBin API key to prefs and update internet service.
  Future<void> saveJsonBinApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('jsonbin_api_key', key);
    internet.jsonBinApiKey = key;
    notifyListeners();
  }

  void _addLog(String entry) {
    final ts = DateTime.now();
    final time = '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    eventLog.add('[$time] $entry');
    if (eventLog.length > 50) eventLog.removeAt(0);
  }

  @override
  void dispose() {
    sms.dispose();
    internet.dispose();
    super.dispose();
  }
}
