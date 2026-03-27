import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sms_gateway_service.dart';
import 'internet_gateway_service.dart';
import 'rescue_bridge_service.dart';
import 'storage_service.dart';
import 'nearby_service.dart';

enum GatewayStatus {
  idle,          
  attempting,    
  smsSent,       
  internetUploaded, 
  rescueHandoff,   
}

class GatewayService extends ChangeNotifier {
  final SmsGatewayService sms;
  final InternetGatewayService internet;
  final RescueBridgeService rescue;

  GatewayStatus _status = GatewayStatus.idle;
  GatewayStatus get status => _status;

  
  final List<String> eventLog = [];

  GatewayService({
    required StorageService storage,
    required NearbyService nearby,
  })  : sms = SmsGatewayService(storage: storage, nearby: nearby),
        internet = InternetGatewayService(storage: storage, nearby: nearby),
        rescue = RescueBridgeService(storage: storage, nearby: nearby);

  
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

    
    _addLog('Gateway monitoring started');
    notifyListeners();
  }

  
  Future<void> hardSOSActivated() async {
    _status = GatewayStatus.attempting;
    _addLog('Hard SOS — firing all channels');
    notifyListeners();

    await Future.wait([
      sms.forceSend(),
      internet.forceUpload(),
    ]);

    
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

  
  Future<void> onPeerConnected(String peerId, String peerName) async {
    await rescue.onPeerConnected(peerId, peerName);
    if (rescue.handoffsCompleted > 0) {
      _status = GatewayStatus.rescueHandoff;
      _addLog('Census handed off to $peerName');
      notifyListeners();
    }
  }

  
  Future<void> saveEmergencyContacts(List<String> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('emergency_contacts', contacts);
    sms.setEmergencyContacts(contacts);
    notifyListeners();
  }

  
  Future<void> saveGatewayUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gateway_url', url);
    internet.gatewayUrl = url;
    notifyListeners();
  }

  
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
