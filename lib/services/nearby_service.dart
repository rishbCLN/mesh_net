import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/location_update.dart';
import '../models/message.dart';
import '../models/resource.dart';
import '../models/roll_call.dart';
import '../models/triage_status.dart';
import '../core/constants.dart';
import 'danger_zone_service.dart';
import 'media_message_service.dart';
import 'storage_service.dart';
import '../utils/battery_helper.dart';
import '../utils/wake_lock_helper.dart';

class NearbyService extends ChangeNotifier {
  final Nearby _nearby = Nearby();
  final StorageService _storage = StorageService();
  final Uuid _uuid = const Uuid();
  final Set<String> _seenMessageIds = {};
  final Queue<String> _messageIdOrder = Queue<String>();

  String userName = '';
  String get myEndpointId => userName; 

  
  String? meshError;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  List<Device> discoveredDevices = [];
  List<Device> connectedDevices = [];

  
  final List<RelayEvent> relayEvents = [];
  static const _kRelayEventTTL = Duration(seconds: 4);

  int _totalMessagesRouted = 0;
  int get totalMessagesRouted => _totalMessagesRouted;
  int get totalMessages => _seenMessageIds.length;

  
  LocationUpdate? myLocation;
  final Map<String, LocationUpdate> peerLocations = {};
  final Map<String, LocationUpdate> peerLocationsByEndpoint = {};
  bool _isFetchingLocation = false;
  Timer? _locationBroadcastTimer;
  StreamSubscription<Position>? _positionStreamSub;
  Position? _lastStreamedPosition;
  double totalDistanceTraveled = 0.0;
  double myHeading = 0.0; 

  
  TriageStatus myTriageStatus = TriageStatus.ok;

  
  final Map<String, ResourceBroadcast> peerResources = {}; 
  final Set<String> _seenResIds = {}; 

  
  RollCallSession? activeRollCall;     
  IncomingRollCall? incomingRollCall;  

  final Set<String> _seenRcIds  = {}; 
  final Set<String> _seenRcrIds = {}; 

  Timer? _rollCallDeadlineTimer;
  Timer? _rollCallRepeatTimer;

  static const _kRollCallDeadline = 60; 
  static const _kRollCallRepeat   = 120; 

  
  Future<void> startRollCall() async {
    stopRollCall(); 
    final id = _uuid.v4();
    final deadline = DateTime.now().add(const Duration(seconds: _kRollCallDeadline));
    final entries = <String, RollCallEntry>{};
    for (final d in connectedDevices) {
      entries[d.name] = RollCallEntry(name: d.name);
    }
    activeRollCall = RollCallSession(
      id: id,
      coordinatorName: userName,
      startedAt: DateTime.now(),
      deadline: deadline,
      entries: entries,
    );
    notifyListeners();
    await _broadcastRollCall(activeRollCall!);
    _scheduleRollCallDeadline();
  }

  
  Future<void> respondToRollCall(String status) async {
    final rc = incomingRollCall;
    if (rc == null) return;
    incomingRollCall = null;
    notifyListeners();
    final reply = RollCallReplyPacket(
      rollCallId: rc.id,
      responderName: userName,
      status: status,
    );
    final bytes = Uint8List.fromList(utf8.encode(Constants.RCR_PREFIX + reply.toWire()));
    for (final d in connectedDevices) {
      await _nearby.sendBytesPayload(d.id, bytes);
    }
  }

  
  void stopRollCall() {
    _rollCallDeadlineTimer?.cancel();
    _rollCallRepeatTimer?.cancel();
    activeRollCall = null;
    notifyListeners();
  }

  Future<void> _broadcastRollCall(RollCallSession session) async {
    final packet = RollCallPacket(
      id: session.id,
      coordinatorName: session.coordinatorName,
      round: session.round,
      deadlineSecs: _kRollCallDeadline,
    );
    final bytes = Uint8List.fromList(utf8.encode(Constants.RC_PREFIX + packet.toWire()));
    for (final d in connectedDevices) {
      await _nearby.sendBytesPayload(d.id, bytes);
    }
  }

  void _scheduleRollCallDeadline() {
    _rollCallDeadlineTimer?.cancel();
    _rollCallDeadlineTimer = Timer(const Duration(seconds: _kRollCallDeadline), () {
      final rc = activeRollCall;
      if (rc == null) return;
      
      for (final e in rc.entries.values) {
        if (e.status == RollCallEntryStatus.pending) {
          e.status = RollCallEntryStatus.unknown;
        }
      }
      notifyListeners();
      
      _rollCallRepeatTimer?.cancel();
      _rollCallRepeatTimer = Timer(const Duration(seconds: _kRollCallRepeat), () {
        final cur = activeRollCall;
        if (cur == null) return;
        
        cur.round++;
        final deadline = DateTime.now().add(const Duration(seconds: _kRollCallDeadline));
        activeRollCall = RollCallSession(
          id: cur.id,
          coordinatorName: cur.coordinatorName,
          startedAt: cur.startedAt,
          deadline: deadline,
          round: cur.round,
          entries: {
            for (final d in connectedDevices) d.name: RollCallEntry(name: d.name),
          },
        );
        notifyListeners();
        _broadcastRollCall(activeRollCall!);
        _scheduleRollCallDeadline();
      });
    });
  }

  
  Future<void> setTriageStatus(TriageStatus status) async {
    myTriageStatus = status;
    notifyListeners();
    if (myLocation != null) {
      
      myLocation = LocationUpdate(
        userId: userName,
        userName: userName,
        latitude: myLocation!.latitude,
        longitude: myLocation!.longitude,
        timestamp: DateTime.now(),
        isSOS: status == TriageStatus.sos,
        triageStatus: status,
        heading: myHeading,
      );
      final payload = Constants.LOC_PREFIX + myLocation!.toJson();
      final bytes = Uint8List.fromList(utf8.encode(payload));
      for (final device in connectedDevices) {
        await _nearby.sendBytesPayload(device.id, bytes);
      }
    } else {
      
      try {
        await startLocationBroadcast();
      } catch (_) {}
    }
  }

  
  Future<void> Function(String peerId, String peerName)? onPeerConnectedCallback;

  
  DangerZoneService? dangerZoneService;

  static const _kTimeout = Duration(seconds: 15);
  static const _kMaxRetries = 3;

  Future<void> init(String name) async {
    userName = name;
    meshError = null;
    _isRunning = false;
    notifyListeners();

    
    try { await _nearby.stopAdvertising(); } catch (_) {}
    try { await _nearby.stopDiscovery(); } catch (_) {}
    try { await _nearby.stopAllEndpoints(); } catch (_) {}
    _locationBroadcastTimer?.cancel();

    
    bool locationOn = false;
    try {
      locationOn = await Geolocator.isLocationServiceEnabled();
    } catch (_) {}
    if (!locationOn) {
      meshError = 'Location Services are OFF. Please turn on GPS/Location in device settings, then tap Retry.';
      notifyListeners();
      return;
    }

    
    await Future.delayed(const Duration(milliseconds: 500));

    final advOk = await _startAdvertising();
    
    await Future.delayed(const Duration(milliseconds: 300));
    final disOk = await _startDiscovery();

    _isRunning = advOk || disOk;

    if (!advOk && !disOk) {
      meshError = 'Could not start mesh — ensure WiFi, Bluetooth, and Location are ON, '
          'and all permissions are granted. Tap Retry.';
    } else if (!advOk) {
      meshError = 'Advertising failed — others may not find this device.';
    } else if (!disOk) {
      meshError = 'Discovery failed — this device may not find others.';
    }

    if (_isRunning) {
      
      await WakeLockHelper.acquire();
      
      _startLocationHeartbeat();
      unawaited(startLocationBroadcast());
    }
    notifyListeners();
  }

  
  Future<bool> _startAdvertising() async {
    for (var attempt = 1; attempt <= _kMaxRetries; attempt++) {
      try {
        final result = await _nearby
            .startAdvertising(
              userName,
              Strategy.P2P_CLUSTER,
              onConnectionInitiated: _onConnectionInitiated,
              onConnectionResult: _onConnectionResult,
              onDisconnected: _onDisconnected,
              serviceId: Constants.SERVICE_ID,
            )
            .timeout(_kTimeout);
        if (result) {
          debugPrint('Advertising started (attempt $attempt)');
          return true;
        }
        debugPrint('Advertising returned false (attempt $attempt)');
      } catch (e) {
        debugPrint('Error starting advertising (attempt $attempt): $e');
      }
      if (attempt < _kMaxRetries) {
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    return false;
  }

  
  Future<bool> _startDiscovery() async {
    for (var attempt = 1; attempt <= _kMaxRetries; attempt++) {
      try {
        final result = await _nearby
            .startDiscovery(
              userName,
              Strategy.P2P_CLUSTER,
              onEndpointFound: _onEndpointFound,
              onEndpointLost: _onEndpointLost,
              serviceId: Constants.SERVICE_ID,
            )
            .timeout(_kTimeout);
        if (result) {
          debugPrint('Discovery started (attempt $attempt)');
          return true;
        }
        debugPrint('Discovery returned false (attempt $attempt)');
      } catch (e) {
        debugPrint('Error starting discovery (attempt $attempt): $e');
      }
      if (attempt < _kMaxRetries) {
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    return false;
  }

  
  
  
  
  
  
  
  
  
  
  
  
  

  final Set<String> _pendingRequests = {};
  final Map<String, int> _retryCount = {};   
  final Map<String, String> _endpointNames = {}; 
  static const int _kMaxConnRetries = 5;

  void _onEndpointFound(String endpointId, String endpointName, String serviceId) async {
    debugPrint('[MESH] Endpoint found: $endpointName ($endpointId)');

    
    if (connectedDevices.any((d) => d.id == endpointId)) {
      debugPrint('[MESH] Already connected to $endpointId, ignoring discovery');
      return;
    }

    
    _endpointNames[endpointId] = endpointName;

    
    
    discoveredDevices.removeWhere(
        (d) => d.name == endpointName && d.id != endpointId);

    
    if (!discoveredDevices.any((d) => d.id == endpointId)) {
      discoveredDevices.add(Device(
        id: endpointId,
        name: endpointName,
        isConnected: false,
      ));
      notifyListeners();
    }

    
    
    
    
    if (userName.compareTo(endpointName) > 0) {
      debugPrint('[MESH] Waiting for $endpointName to initiate (they have priority)');
      
      
      
      Future.delayed(const Duration(seconds: 8), () {
        if (!_isRunning) return;
        if (connectedDevices.any((d) => d.id == endpointId)) return;
        if (_pendingRequests.contains(endpointId)) return;
        debugPrint('[MESH] Safety-net: $endpointName did not initiate, we will try');
        _initiateConnection(endpointId);
      });
      return;
    }

    
    _initiateConnection(endpointId);
  }

  
  Future<void> _initiateConnection(String endpointId) async {
    if (!_isRunning) return;
    if (connectedDevices.any((d) => d.id == endpointId)) return;
    if (_pendingRequests.contains(endpointId)) {
      debugPrint('[MESH] Request already pending for $endpointId, skipping');
      return;
    }

    final attempts = _retryCount[endpointId] ?? 0;
    if (attempts >= _kMaxConnRetries) {
      debugPrint('[MESH] Max retries reached for $endpointId, giving up');
      _retryCount.remove(endpointId);
      _pendingRequests.remove(endpointId);
      return;
    }

    _pendingRequests.add(endpointId);
    debugPrint('[MESH] requestConnection to $endpointId (attempt ${attempts + 1})');

    try {
      await _nearby.requestConnection(
        userName,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      debugPrint('[MESH] requestConnection error for $endpointId: $e');
      _pendingRequests.remove(endpointId);
      _retryCount[endpointId] = attempts + 1;

      
      final delaySecs = 2 * (1 << attempts);
      debugPrint('[MESH] Will retry $endpointId in ${delaySecs}s');
      Future.delayed(Duration(seconds: delaySecs), () {
        if (!_isRunning) return;
        if (connectedDevices.any((d) => d.id == endpointId)) return;
        if (discoveredDevices.any((d) => d.id == endpointId)) {
          _initiateConnection(endpointId);
        }
      });
    }
  }

  void _onEndpointLost(String? endpointId) {
    debugPrint('[MESH] Endpoint lost: $endpointId');
    if (endpointId != null) {
      _pendingRequests.remove(endpointId);
      _retryCount.remove(endpointId);
      _endpointNames.remove(endpointId);
      discoveredDevices.removeWhere((d) => d.id == endpointId);
      notifyListeners();
    }
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    debugPrint('[MESH] Connection initiated with: ${info.endpointName} ($endpointId)');

    
    if (info.endpointName.isNotEmpty) {
      _endpointNames[endpointId] = info.endpointName;
    }

    
    
    _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    debugPrint('[MESH] Connection result for $endpointId: ${status.toString()}');
    _pendingRequests.remove(endpointId);

    if (status == Status.CONNECTED) {
      
      _retryCount.remove(endpointId);

      
      final cachedName = _endpointNames[endpointId];
      final device = discoveredDevices.firstWhere(
        (d) => d.id == endpointId,
        orElse: () => Device(
          id: endpointId,
          name: cachedName ?? 'Unknown',
          isConnected: false,
        ),
      );

      discoveredDevices.removeWhere((d) => d.id == endpointId);
      
      discoveredDevices.removeWhere((d) => d.name == device.name);

      if (!connectedDevices.any((d) => d.id == endpointId)) {
        
        connectedDevices.removeWhere(
            (d) => d.name == device.name && d.id != endpointId);
        connectedDevices.add(device.copyWith(isConnected: true));
      }

      
      unawaited(startLocationBroadcast());

      
      onPeerConnectedCallback?.call(endpointId, device.name);

      notifyListeners();
      debugPrint('[MESH] Connected to ${device.name}. Total: ${connectedDevices.length}');
    } else {
      
      final attempts = _retryCount[endpointId] ?? 0;
      _retryCount[endpointId] = attempts + 1;

      if (attempts + 1 >= _kMaxConnRetries) {
        debugPrint('[MESH] Connection to $endpointId permanently failed after ${attempts + 1} attempts');
        _retryCount.remove(endpointId);
        return;
      }

      
      final delaySecs = 2 * (1 << attempts);
      debugPrint('[MESH] Connection to $endpointId failed ($status), retry in ${delaySecs}s');
      Future.delayed(Duration(seconds: delaySecs), () {
        if (!_isRunning) return;
        if (connectedDevices.any((d) => d.id == endpointId)) return;
        if (discoveredDevices.any((d) => d.id == endpointId)) {
          _initiateConnection(endpointId);
        }
      });
    }
  }

  void _onDisconnected(String endpointId) {
    debugPrint('[MESH] Disconnected from: $endpointId');
    _pendingRequests.remove(endpointId);
    _retryCount.remove(endpointId);
    final disconnectedDevice = connectedDevices.firstWhere(
      (d) => d.id == endpointId,
      orElse: () => Device(id: endpointId, name: _endpointNames[endpointId] ?? 'Unknown', isConnected: false),
    );
    connectedDevices.removeWhere((d) => d.id == endpointId);
    peerLocationsByEndpoint.remove(endpointId);

    
    if (!discoveredDevices.any((d) => d.id == endpointId)) {
      discoveredDevices.add(Device(
        id: endpointId,
        name: disconnectedDevice.name,
        isConnected: false,
      ));
    }
    notifyListeners();

    
    Future.delayed(const Duration(seconds: 2), () {
      if (!_isRunning) return;
      if (connectedDevices.any((d) => d.id == endpointId)) return;
      debugPrint('[MESH] Auto-reconnecting to ${disconnectedDevice.name}');
      _initiateConnection(endpointId);
    });
  }

  void _onPayloadReceived(String endpointId, Payload payload) async {
    
    if (payload.type == PayloadType.FILE) {
      _handleIncomingFilePayload(payload);
      return;
    }

    if (payload.type != PayloadType.BYTES) {
      return;
    }

    final bytes = payload.bytes;
    if (bytes == null) {
      return;
    }

    final String data = utf8.decode(bytes);
    debugPrint('Received message: $data');

    
    if (data.startsWith(Constants.MEDIA_META_PREFIX)) {
      _handleMediaMetadata(data.substring(Constants.MEDIA_META_PREFIX.length), payload.id);
      return;
    }

    
    if (data.startsWith(Constants.RES_PREFIX)) {
      _handleResourcePacket(endpointId, data.substring(Constants.RES_PREFIX.length));
      return;
    }

    
    if (data.startsWith(Constants.DANGER_PREFIX)) {
      _handleDangerPacket(endpointId, data);
      return;
    }

    
    if (data.startsWith(Constants.DIMG_PREFIX)) {
      _handleDangerImagePacket(endpointId, data);
      return;
    }

    
    if (data.startsWith(Constants.GW_PREFIX) || data.startsWith(Constants.CENSUS_PREFIX)) {
      debugPrint('[GATEWAY] Received gateway packet from $endpointId');
      return;
    }

    
    if (data.startsWith(Constants.RC_PREFIX)) {
      _handleRollCallPacket(endpointId, data.substring(Constants.RC_PREFIX.length));
      return;
    }

    
    if (data.startsWith(Constants.RCR_PREFIX)) {
      _handleRollCallReplyPacket(endpointId, data.substring(Constants.RCR_PREFIX.length));
      return;
    }

    
    if (data.startsWith(Constants.LOC_PREFIX)) {
      try {
        final locJson = data.substring(Constants.LOC_PREFIX.length);
        final loc = LocationUpdate.fromJson(locJson);
        peerLocations[loc.userId] = loc;
        peerLocationsByEndpoint[endpointId] = loc;
        notifyListeners();
      } catch (e) {
        debugPrint('Error parsing location update: $e');
      }
      return;
    }

    try {
      final message = Message.fromJson(data);

      if (_seenMessageIds.contains(message.id)) {
        return;
      }

      _rememberMessageId(message.id);

      
      Message dbMessage = message;
      if (message.mediaBase64 != null && message.mediaBase64!.isNotEmpty) {
        try {
          final mediaDir = await MediaMessageService.getReceivedMediaDir();
          final ext = message.mediaType == 'photo' ? 'jpg' : 'ogg';
          final fileName = '${message.id}.$ext';
          final destPath = '$mediaDir/$fileName';
          final decoded = base64Decode(message.mediaBase64!);
          await File(destPath).writeAsBytes(decoded);
          dbMessage = message.copyWith(mediaPath: destPath);
        } catch (e) {
          debugPrint('[MEDIA] Error saving received media: $e');
        }
      }

      await _storage.insertMessage(dbMessage);
      notifyListeners();

      
      if (message.isSOS) {
        HapticFeedback.heavyImpact();
      }

      if (message.hopCount < message.maxHops) {
        final forwarded = message.copyWith(hopCount: message.hopCount + 1);
        final payloadBytes = Uint8List.fromList(utf8.encode(forwarded.toJson()));

        
        _totalMessagesRouted++;
        final relayTargets = <String>[];

        for (var device in connectedDevices) {
          if (device.id == endpointId) {
            continue; 
          }
          await _nearby.sendBytesPayload(device.id, payloadBytes);
          relayTargets.add(device.id);
        }

        
        final now = DateTime.now();
        
        relayEvents.removeWhere(
          (e) => now.difference(e.timestamp) > _kRelayEventTTL,
        );
        for (final targetId in relayTargets) {
          relayEvents.add(RelayEvent(
            fromId: endpointId,
            toId: targetId,
            timestamp: now,
            isSOS: message.isSOS,
          ));
        }
        if (relayTargets.isNotEmpty) notifyListeners();
      }
    } catch (e) {
      debugPrint('Error parsing message: $e');
    }
  }

  

  void _handleMediaMetadata(String jsonStr, int payloadId) {
    try {
      final meta = jsonDecode(jsonStr) as Map<String, dynamic>;
      _pendingMediaMeta[payloadId] = meta;
      debugPrint('[MEDIA] Stored metadata for payload $payloadId: ${meta['type']}');
    } catch (e) {
      debugPrint('[MEDIA] Error parsing media metadata: $e');
    }
  }

  void _handleIncomingFilePayload(Payload payload) async {
    
    final uri = payload.uri;
    if (uri == null || uri.isEmpty) {
      debugPrint('[MEDIA] FILE payload has no uri');
      return;
    }

    
    
    
    
    Map<String, dynamic>? meta;
    int? metaKey;
    if (_pendingMediaMeta.isNotEmpty) {
      metaKey = _pendingMediaMeta.keys.last;
      meta = _pendingMediaMeta.remove(metaKey);
    }

    if (meta == null) {
      debugPrint('[MEDIA] No pending metadata for incoming file payload');
      return;
    }

    try {
      final mediaDir = await MediaMessageService.getReceivedMediaDir();
      final fileName = meta['fileName'] as String? ?? '${_uuid.v4()}.dat';
      final destPath = '$mediaDir/$fileName';

      
      final sourceFile = File(uri);
      if (await sourceFile.exists()) {
        await sourceFile.copy(destPath);
        await sourceFile.delete();
      } else {
        
        final altFile = File(uri.replaceFirst('file://', ''));
        if (await altFile.exists()) {
          await altFile.copy(destPath);
          await altFile.delete();
        } else {
          debugPrint('[MEDIA] Source file not found: $uri');
          return;
        }
      }

      final type = meta['type'] as String;
      final messageId = meta['messageId'] as String;
      final senderName = meta['senderName'] as String;
      final senderLat = (meta['senderLat'] as num?)?.toDouble() ?? 0.0;
      final senderLng = (meta['senderLng'] as num?)?.toDouble() ?? 0.0;
      final durationSeconds = (meta['durationSeconds'] as int?) ?? 0;

      final contentText = type == 'photo' ? '📷 Photo' : '🎤 Voice (${durationSeconds}s)';

      final message = Message(
        id: messageId,
        senderId: senderName,
        senderName: senderName,
        content: contentText,
        timestamp: DateTime.now(),
        isSOS: false,
        hopCount: 0,
        maxHops: 3,
        originId: messageId,
        mediaType: type,
        mediaPath: destPath,
        senderLat: senderLat,
        senderLng: senderLng,
      );

      if (!_seenMessageIds.contains(message.id)) {
        _rememberMessageId(message.id);
        await _storage.insertMessage(message);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[MEDIA] Error handling file payload: $e');
    }
  }

  
  
  
  Future<void> broadcastMediaFile({
    required String filePath,
    required String metadataJson,
    required Message localMessage,
  }) async {
    _rememberMessageId(localMessage.id);
    await _storage.insertMessage(localMessage);

    
    final fileBytes = await File(filePath).readAsBytes();
    final b64 = base64Encode(fileBytes);

    
    final wireMessage = localMessage.copyWith(mediaBase64: b64);
    final payloadBytes = Uint8List.fromList(utf8.encode(wireMessage.toJson()));

    for (final device in connectedDevices) {
      try {
        await _nearby.sendBytesPayload(device.id, payloadBytes);
      } catch (e) {
        debugPrint('[MEDIA] Error sending to ${device.id}: $e');
      }
    }

    notifyListeners();
  }

  Future<void> sendMessage(String endpointId, String content) async {
    final id = _uuid.v4();
    final battery = await getBatteryLevel();
    final message = Message(
      id: id,
      senderId: myEndpointId,
      senderName: userName,
      content: content,
      timestamp: DateTime.now(),
      isSOS: false,
      hopCount: 0,
      maxHops: 5,
      originId: id,
      senderLat: myLocation?.latitude,
      senderLng: myLocation?.longitude,
      senderBattery: battery,
    );

    _rememberMessageId(message.id);

    
    await _storage.insertMessage(message);

    
    final bytes = Uint8List.fromList(utf8.encode(message.toJson()));

    await _nearby.sendBytesPayload(endpointId, bytes);
    notifyListeners();
  }

  Future<void> broadcastMessage(String content) async {
    final id = _uuid.v4();
    final battery = await getBatteryLevel();
    final message = Message(
      id: id,
      senderId: myEndpointId,
      senderName: userName,
      content: content,
      timestamp: DateTime.now(),
      isSOS: false,
      hopCount: 0,
      maxHops: 5,
      originId: id,
      senderLat: myLocation?.latitude,
      senderLng: myLocation?.longitude,
      senderBattery: battery,
    );

    _rememberMessageId(message.id);

    
    await _storage.insertMessage(message);

    
    final bytes = Uint8List.fromList(utf8.encode(message.toJson()));
    for (var device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }
    
    notifyListeners();
  }

  
  
  Future<void> broadcastImageMessage(List<int> imageBytes, {String caption = '📷 Photo'}) async {
    final id = _uuid.v4();
    final imgB64 = base64Encode(imageBytes);
    final message = Message(
      id: id,
      senderId: myEndpointId,
      senderName: userName,
      content: caption,
      timestamp: DateTime.now(),
      isSOS: false,
      hopCount: 0,
      maxHops: 3, 
      originId: id,
      imageBase64: imgB64,
    );

    _rememberMessageId(message.id);
    await _storage.insertMessage(message);

    final bytes = Uint8List.fromList(utf8.encode(message.toJson()));
    for (var device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }

    notifyListeners();
  }

  Future<void> sendSOS(String content) async {
    final sosContent = '${Constants.SOS_PREFIX}$content';
    final id = _uuid.v4();
    final battery = await getBatteryLevel();
    final message = Message(
      id: id,
      senderId: myEndpointId,
      senderName: userName,
      content: sosContent,
      timestamp: DateTime.now(),
      isSOS: true,
      hopCount: 0,
      originId: id,
      senderLat: myLocation?.latitude,
      senderLng: myLocation?.longitude,
      senderBattery: battery,
    );

    _rememberMessageId(message.id);

    
    await _storage.insertMessage(message);

    
    final bytes = Uint8List.fromList(utf8.encode(message.toJson()));
    for (var device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }
    
    notifyListeners();
  }

  Future<void> disconnect() async {
    try { await _nearby.stopAdvertising(); } catch (_) {}
    try { await _nearby.stopDiscovery(); } catch (_) {}
    try { await _nearby.stopAllEndpoints(); } catch (_) {}
    await WakeLockHelper.release();
    _locationBroadcastTimer?.cancel();
    _locationBroadcastTimer = null;
    _positionStreamSub?.cancel();
    _positionStreamSub = null;
    _lastStreamedPosition = null;
    _distSinceLastSave = 0.0;
    totalDistanceTraveled = 0.0;

    _isRunning = false;
    meshError = null;
    _pendingRequests.clear();
    _retryCount.clear();
    _endpointNames.clear();
    discoveredDevices.clear();
    connectedDevices.clear();
    peerLocations.clear();
    peerLocationsByEndpoint.clear();
    notifyListeners();
  }

  void _startLocationHeartbeat() {
    _locationBroadcastTimer?.cancel();
    
    
    _locationBroadcastTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_isRunning) return;
      final loc = myLocation;
      if (loc == null || connectedDevices.isEmpty) return;
      try {
        final payload = Constants.LOC_PREFIX + loc.toJson();
        final bytes = Uint8List.fromList(utf8.encode(payload));
        for (final device in connectedDevices) {
          try { await _nearby.sendBytesPayload(device.id, bytes); } catch (_) {}
        }
      } catch (_) {}
    });
  }

  
  
  Future<void> startLocationBroadcast() async {
    if (_isFetchingLocation) return;
    _isFetchingLocation = true;
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('Location services disabled');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('Location permission denied');
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        debugPrint('Location permission permanently denied');
        return;
      }

      Position? position;

      
      
      if (_positionStreamSub == null) {
        _startPositionStream();
      }

      
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (_) {}
      if (position != null) {
        if (position.heading >= 0) myHeading = position.heading;
        _lastStreamedPosition = position;
        myLocation = LocationUpdate(
          userId: userName,
          userName: userName,
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now(),
          isSOS: myTriageStatus == TriageStatus.sos,
          triageStatus: myTriageStatus,
          heading: myHeading,
        );
        notifyListeners();
      }

      
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('GPS fresh fix failed: $e');
        
      }

      if (position != null) {
        _lastStreamedPosition = position;
      }

      
      if (position != null && position.heading >= 0) {
        myHeading = position.heading;
      }

      if (position != null) {
        myLocation = LocationUpdate(
          userId: userName,
          userName: userName,
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now(),
          isSOS: myTriageStatus == TriageStatus.sos,
          triageStatus: myTriageStatus,
          heading: myHeading,
        );
        notifyListeners();

        
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('lastLat', position.latitude);
          await prefs.setDouble('lastLng', position.longitude);
        } catch (_) {}
      }

      
      if (myLocation != null) {
        final payload = Constants.LOC_PREFIX + myLocation!.toJson();
        final bytes = Uint8List.fromList(utf8.encode(payload));
        for (final device in connectedDevices) {
          try { await _nearby.sendBytesPayload(device.id, bytes); } catch (_) {}
        }
        debugPrint('Location broadcast: ${myLocation!.latitude}, ${myLocation!.longitude}');
      }
    } catch (e) {
      debugPrint('Error broadcasting location: $e');
    } finally {
      _isFetchingLocation = false;
    }
  }

  
  
  
  
  
  
  
  
  
  
  
  double _distSinceLastSave = 0.0;

  void _startPositionStream() {
    _positionStreamSub?.cancel();

    
    
    final LocationSettings locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3,
            intervalDuration: const Duration(seconds: 1),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3,
          );

    _positionStreamSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) async {
        
        if (position.heading >= 0) {
          myHeading = position.heading;
        }

        
        
        
        final bool speedAvailable = position.speed >= 0;
        final bool reallyMoving = !speedAvailable || position.speed >= 0.4;

        if (!reallyMoving) {
          
          notifyListeners();
          return;
        }

        
        if (_lastStreamedPosition != null) {
          final delta = Geolocator.distanceBetween(
            _lastStreamedPosition!.latitude,
            _lastStreamedPosition!.longitude,
            position.latitude,
            position.longitude,
          );
          totalDistanceTraveled += delta;
          _distSinceLastSave += delta;
        }
        _lastStreamedPosition = position;

        
        if (_distSinceLastSave >= 50.0) {
          _distSinceLastSave = 0.0;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble('lastLat', position.latitude);
            await prefs.setDouble('lastLng', position.longitude);
          } catch (_) {}
        }

        
        myLocation = LocationUpdate(
          userId: userName,
          userName: userName,
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now(),
          isSOS: myTriageStatus == TriageStatus.sos,
          triageStatus: myTriageStatus,
          heading: myHeading,
        );
        notifyListeners();

        
        if (_isRunning && connectedDevices.isNotEmpty) {
          final payload = Constants.LOC_PREFIX + myLocation!.toJson();
          final bytes = Uint8List.fromList(utf8.encode(payload));
          for (final device in connectedDevices) {
            try { await _nearby.sendBytesPayload(device.id, bytes); } catch (_) {}
          }
        }
      },
      onError: (e) => debugPrint('[GPS stream error] $e'),
    );
  }

  void _rememberMessageId(String id) {
    if (_seenMessageIds.contains(id)) {
      return;
    }

    _seenMessageIds.add(id);
    _messageIdOrder.addLast(id);

    if (_messageIdOrder.length > 500) {
      for (var i = 0; i < 100 && _messageIdOrder.isNotEmpty; i++) {
        final oldest = _messageIdOrder.removeFirst();
        _seenMessageIds.remove(oldest);
      }
    }
  }

  

  
  Future<void> sendBytesToPeer(String peerId, Uint8List bytes) async {
    await _nearby.sendBytesPayload(peerId, bytes);
  }

  
  Future<void> broadcastResource(ResourceBroadcast resource) async {
    final key = '${resource.userId}:${resource.resourceType.jsonValue}:${resource.isOffering}';
    peerResources[key] = resource;
    _seenResIds.add(key);
    notifyListeners();

    final payload = Constants.RES_PREFIX + resource.toJson();
    final bytes = Uint8List.fromList(utf8.encode(payload));
    for (final device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }
  }

  void _handleResourcePacket(String fromEndpointId, String wire) async {
    ResourceBroadcast res;
    try {
      res = ResourceBroadcast.fromJson(wire);
    } catch (_) {
      return;
    }

    final key = '${res.userId}:${res.resourceType.jsonValue}:${res.isOffering}';
    if (_seenResIds.contains(key)) return;
    _seenResIds.add(key);

    peerResources[key] = res;
    notifyListeners();

    
    final relayed = Uint8List.fromList(utf8.encode(Constants.RES_PREFIX + wire));
    for (final d in connectedDevices) {
      if (d.id == fromEndpointId) continue;
      await _nearby.sendBytesPayload(d.id, relayed);
    }
  }

  

  final Set<String> _seenDangerIds = {};
  final Set<String> _seenDimgChunks = {};

  
  final Map<int, Map<String, dynamic>> _pendingMediaMeta = {};

  void _handleDangerPacket(String fromEndpointId, String data) async {
    final payload = data.substring(Constants.DANGER_PREFIX.length);
    
    String? zoneId;
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      zoneId = json['id'] as String?;
    } catch (_) {
      return;
    }
    if (zoneId == null || _seenDangerIds.contains(zoneId)) return;
    _seenDangerIds.add(zoneId);

    
    dangerZoneService?.handleDangerPayload(payload);

    
    final relayBytes = Uint8List.fromList(utf8.encode(data));
    for (final d in connectedDevices) {
      if (d.id == fromEndpointId) continue;
      await _nearby.sendBytesPayload(d.id, relayBytes);
    }
  }

  void _handleDangerImagePacket(String fromEndpointId, String data) async {
    final payload = data.substring(Constants.DIMG_PREFIX.length);
    
    final parts = payload.split('::');
    if (parts.length < 4) return;
    final dedupKey = '${parts[0]}::${parts[1]}';
    if (_seenDimgChunks.contains(dedupKey)) return;
    _seenDimgChunks.add(dedupKey);

    
    dangerZoneService?.handleImageChunk(payload);

    
    final relayBytes = Uint8List.fromList(utf8.encode(data));
    for (final d in connectedDevices) {
      if (d.id == fromEndpointId) continue;
      await _nearby.sendBytesPayload(d.id, relayBytes);
    }
  }

  
  Future<void> broadcastDangerZone(DangerZoneBroadcast broadcast) async {
    
    final metaBytes = Uint8List.fromList(
        utf8.encode(Constants.DANGER_PREFIX + broadcast.metadataPayload));
    for (final d in connectedDevices) {
      await _nearby.sendBytesPayload(d.id, metaBytes);
    }

    
    for (final chunk in broadcast.imageChunkPayloads) {
      await Future.delayed(const Duration(milliseconds: 50));
      final chunkBytes = Uint8List.fromList(
          utf8.encode(Constants.DIMG_PREFIX + chunk));
      for (final d in connectedDevices) {
        await _nearby.sendBytesPayload(d.id, chunkBytes);
      }
    }
  }

  

  void _handleRollCallPacket(String fromEndpointId, String wire) async {
    RollCallPacket pkt;
    try { pkt = RollCallPacket.fromWire(wire); } catch (_) { return; }

    final dedupKey = 'rc:${pkt.id}:${pkt.round}';
    if (_seenRcIds.contains(dedupKey)) return;
    _seenRcIds.add(dedupKey);

    
    if (activeRollCall?.id == pkt.id) return;

    
    if (incomingRollCall?.id != pkt.id) {
      incomingRollCall = IncomingRollCall(
        id: pkt.id,
        coordinatorName: pkt.coordinatorName,
        receivedAt: DateTime.now(),
        deadlineSecs: pkt.deadlineSecs,
      );
      notifyListeners();
      
      Timer(Duration(seconds: pkt.deadlineSecs), () {
        if (incomingRollCall?.id == pkt.id) {
          incomingRollCall = null;
          notifyListeners();
        }
      });
    }

    
    if (pkt.hops < RollCallPacket.maxHops) {
      final relayed = Uint8List.fromList(
          utf8.encode(Constants.RC_PREFIX + pkt.withNextHop().toWire()));
      for (final d in connectedDevices) {
        if (d.id == fromEndpointId) continue;
        await _nearby.sendBytesPayload(d.id, relayed);
      }
    }
  }

  void _handleRollCallReplyPacket(String fromEndpointId, String wire) async {
    RollCallReplyPacket pkt;
    try { pkt = RollCallReplyPacket.fromWire(wire); } catch (_) { return; }

    final dedupKey = 'rcr:${pkt.rollCallId}:${pkt.responderName}';
    if (_seenRcrIds.contains(dedupKey)) return;
    _seenRcrIds.add(dedupKey);

    
    final rc = activeRollCall;
    if (rc != null && rc.id == pkt.rollCallId) {
      final entry = rc.entries[pkt.responderName];
      if (entry != null && entry.status == RollCallEntryStatus.pending) {
        entry.status = RollCallEntryStatusX.fromJson(pkt.status);
        entry.respondedAt = DateTime.now();
        notifyListeners();
      }
    }

    
    if (pkt.hops < RollCallReplyPacket.maxHops) {
      final relayed = Uint8List.fromList(
          utf8.encode(Constants.RCR_PREFIX + pkt.withNextHop().toWire()));
      for (final d in connectedDevices) {
        if (d.id == fromEndpointId) continue;
        await _nearby.sendBytesPayload(d.id, relayed);
      }
    }
  }
}

class RelayEvent {
  final String fromId;
  final String toId;
  final DateTime timestamp;
  final bool isSOS;

  const RelayEvent({
    required this.fromId,
    required this.toId,
    required this.timestamp,
    this.isSOS = false,
  });
}
