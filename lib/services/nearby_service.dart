import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/location_update.dart';
import '../models/message.dart';
import '../models/resource.dart';
import '../models/roll_call.dart';
import '../models/triage_status.dart';
import '../core/constants.dart';
import 'storage_service.dart';

class NearbyService extends ChangeNotifier {
  final Nearby _nearby = Nearby();
  final StorageService _storage = StorageService();
  final Uuid _uuid = const Uuid();
  final Set<String> _seenMessageIds = {};
  final Queue<String> _messageIdOrder = Queue<String>();

  String userName = '';
  String get myEndpointId => userName; // Use userName as endpoint ID

  /// Non-null when advertising/discovery could not start.
  String? meshError;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  List<Device> discoveredDevices = [];
  List<Device> connectedDevices = [];

  // Relay event log (for topology visualizer)
  final List<RelayEvent> relayEvents = [];
  static const _kRelayEventTTL = Duration(seconds: 4);

  int _totalMessagesRouted = 0;
  int get totalMessagesRouted => _totalMessagesRouted;
  int get totalMessages => _seenMessageIds.length;

  // Location tracking
  LocationUpdate? myLocation;
  final Map<String, LocationUpdate> peerLocations = {};
  final Map<String, LocationUpdate> peerLocationsByEndpoint = {};
  bool _isFetchingLocation = false;
  Timer? _locationBroadcastTimer;

  // Triage
  TriageStatus myTriageStatus = TriageStatus.ok;

  // Resources
  final Map<String, ResourceBroadcast> peerResources = {}; // keyed by 'userId:resourceType:isOffering'
  final Set<String> _seenResIds = {}; // dedup

  // ── Roll Call ────────────────────────────────────────────────────────────
  RollCallSession? activeRollCall;     // non-null only on the coordinator
  IncomingRollCall? incomingRollCall;  // non-null on a responder

  final Set<String> _seenRcIds  = {}; // dedup relay: 'rc:{id}:{round}'
  final Set<String> _seenRcrIds = {}; // dedup relay: 'rcr:{rcId}:{from}'

  Timer? _rollCallDeadlineTimer;
  Timer? _rollCallRepeatTimer;

  static const _kRollCallDeadline = 60; // seconds per round
  static const _kRollCallRepeat   = 120; // seconds between auto-repeats

  /// Start a roll call as coordinator.
  Future<void> startRollCall() async {
    stopRollCall(); // cancel any previous
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

  /// Responder: reply 'safe' or 'needHelp' to a received roll call.
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

  /// Coordinator: stop and clear the roll call.
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
      // Mark all still-pending entries as UNKNOWN
      for (final e in rc.entries.values) {
        if (e.status == RollCallEntryStatus.pending) {
          e.status = RollCallEntryStatus.unknown;
        }
      }
      notifyListeners();
      // Schedule auto-repeat
      _rollCallRepeatTimer?.cancel();
      _rollCallRepeatTimer = Timer(const Duration(seconds: _kRollCallRepeat), () {
        final cur = activeRollCall;
        if (cur == null) return;
        // New round: reset all to pending
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

  /// Update this device's triage status and rebroadcast location immediately.
  Future<void> setTriageStatus(TriageStatus status) async {
    myTriageStatus = status;
    notifyListeners();
    if (myLocation != null) {
      // Rebuild myLocation with new status and push to all peers
      myLocation = LocationUpdate(
        userId: userName,
        userName: userName,
        latitude: myLocation!.latitude,
        longitude: myLocation!.longitude,
        timestamp: DateTime.now(),
        isSOS: status == TriageStatus.sos,
        triageStatus: status,
      );
      final payload = Constants.LOC_PREFIX + myLocation!.toJson();
      final bytes = Uint8List.fromList(utf8.encode(payload));
      for (final device in connectedDevices) {
        await _nearby.sendBytesPayload(device.id, bytes);
      }
    } else {
      // No GPS fix yet — just broadcast without coords by triggering a fresh fix
      try {
        await startLocationBroadcast();
      } catch (_) {}
    }
  }

  // Callback for gateway service to react to new peer connections
  Future<void> Function(String peerId, String peerName)? onPeerConnectedCallback;

  static const _kTimeout = Duration(seconds: 15);
  static const _kMaxRetries = 3;

  Future<void> init(String name) async {
    userName = name;
    meshError = null;
    _isRunning = false;
    notifyListeners();

    // Stop any previous session completely before (re)starting
    try { await _nearby.stopAdvertising(); } catch (_) {}
    try { await _nearby.stopDiscovery(); } catch (_) {}
    try { await _nearby.stopAllEndpoints(); } catch (_) {}
    _locationBroadcastTimer?.cancel();

    // Pre-flight: Location Services must be ON for Nearby Connections
    bool locationOn = false;
    try {
      locationOn = await Geolocator.isLocationServiceEnabled();
    } catch (_) {}
    if (!locationOn) {
      meshError = 'Location Services are OFF. Please turn on GPS/Location in device settings, then tap Retry.';
      notifyListeners();
      return;
    }

    // Small pause after stopping to let radios reset
    await Future.delayed(const Duration(milliseconds: 500));

    final advOk = await _startAdvertising();
    // Brief pause between advertising and discovery to avoid radio contention
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
      // Keep locations fresh so nearby survivors remain visible on the map.
      _startLocationHeartbeat();
      unawaited(startLocationBroadcast());
    }
    notifyListeners();
  }

  /// Returns true on success, false on any error.
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

  /// Returns true on success, false on any error.
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

  void _onEndpointFound(String endpointId, String endpointName, String serviceId) {
    debugPrint('Endpoint found: $endpointName ($endpointId)');
    
    // Add to discovered devices if not already there
    if (!discoveredDevices.any((d) => d.id == endpointId)) {
      discoveredDevices.add(Device(
        id: endpointId,
        name: endpointName,
        isConnected: false,
      ));
      notifyListeners();
    }

    // Auto-request connection
    _nearby.requestConnection(
      userName,
      endpointId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  void _onEndpointLost(String? endpointId) {
    debugPrint('Endpoint lost: $endpointId');
    if (endpointId != null) {
      discoveredDevices.removeWhere((d) => d.id == endpointId);
      notifyListeners();
    }
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    debugPrint('Connection initiated with: ${info.endpointName} ($endpointId)');
    
    // Auto-accept all connections
    _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    debugPrint('Connection result for $endpointId: ${status.toString()}');
    
    if (status == Status.CONNECTED) {
      // Move from discovered to connected
      final device = discoveredDevices.firstWhere(
        (d) => d.id == endpointId,
        orElse: () => Device(
          id: endpointId,
          name: 'Unknown',
          isConnected: false,
        ),
      );
      
      discoveredDevices.removeWhere((d) => d.id == endpointId);
      
      if (!connectedDevices.any((d) => d.id == endpointId)) {
        connectedDevices.add(device.copyWith(isConnected: true));
      }

      // Share my latest location immediately with newly connected peers.
      unawaited(startLocationBroadcast());

      // Notify gateway service of new peer (for rescue bridge auto-dump)
      onPeerConnectedCallback?.call(endpointId, device.name);
      
      notifyListeners();
      debugPrint('Connected to ${device.name}. Total connections: ${connectedDevices.length}');
    }
  }

  void _onDisconnected(String endpointId) {
    debugPrint('Disconnected from: $endpointId');
    connectedDevices.removeWhere((d) => d.id == endpointId);
    discoveredDevices.removeWhere((d) => d.id == endpointId);
    peerLocationsByEndpoint.remove(endpointId);
    notifyListeners();
  }

  void _onPayloadReceived(String endpointId, Payload payload) async {
    if (payload.type != PayloadType.BYTES) {
      return;
    }

    final bytes = payload.bytes;
    if (bytes == null) {
      return;
    }

    final String data = utf8.decode(bytes);
    debugPrint('Received message: $data');

    // Handle resource broadcast
    if (data.startsWith(Constants.RES_PREFIX)) {
      _handleResourcePacket(endpointId, data.substring(Constants.RES_PREFIX.length));
      return;
    }

    // Handle gateway system messages (informational — just log)
    if (data.startsWith(Constants.GW_PREFIX) || data.startsWith(Constants.CENSUS_PREFIX)) {
      debugPrint('[GATEWAY] Received gateway packet from $endpointId');
      return;
    }

    // Handle roll call broadcast
    if (data.startsWith(Constants.RC_PREFIX)) {
      _handleRollCallPacket(endpointId, data.substring(Constants.RC_PREFIX.length));
      return;
    }

    // Handle roll call reply
    if (data.startsWith(Constants.RCR_PREFIX)) {
      _handleRollCallReplyPacket(endpointId, data.substring(Constants.RCR_PREFIX.length));
      return;
    }

    // Handle location update payloads
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

      await _storage.insertMessage(message);
      notifyListeners();

      // Haptic feedback on SOS receive
      if (message.isSOS) {
        HapticFeedback.heavyImpact();
      }

      if (message.hopCount < message.maxHops) {
        final forwarded = message.copyWith(hopCount: message.hopCount + 1);
        final payloadBytes = Uint8List.fromList(utf8.encode(forwarded.toJson()));

        // Track relay for topology visualizer
        _totalMessagesRouted++;
        final relayTargets = <String>[];

        for (var device in connectedDevices) {
          if (device.id == endpointId) {
            continue; // do not echo back to sender
          }
          await _nearby.sendBytesPayload(device.id, payloadBytes);
          relayTargets.add(device.id);
        }

        // Record one relay event per forwarded-to device
        final now = DateTime.now();
        // Prune stale events first
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

  Future<void> sendMessage(String endpointId, String content) async {
    final id = _uuid.v4();
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
    );

    _rememberMessageId(message.id);

    // Save own message to database
    await _storage.insertMessage(message);

    // Send to endpoint
    final bytes = Uint8List.fromList(utf8.encode(message.toJson()));

    await _nearby.sendBytesPayload(endpointId, bytes);
    notifyListeners();
  }

  Future<void> broadcastMessage(String content) async {
    final id = _uuid.v4();
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
    );

    _rememberMessageId(message.id);

    // Save own message to database
    await _storage.insertMessage(message);

    // Broadcast to all connected devices
    final bytes = Uint8List.fromList(utf8.encode(message.toJson()));
    for (var device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }
    
    notifyListeners();
  }

  /// Broadcast an image message to all connected devices.
  /// [imageBytes] should be compressed JPEG bytes (≤100KB ideally).
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
      maxHops: 3, // images are large — limit hops to reduce network load
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
    final message = Message(
      id: id,
      senderId: myEndpointId,
      senderName: userName,
      content: sosContent,
      timestamp: DateTime.now(),
      isSOS: true,
      hopCount: 0,
      originId: id,
    );

    _rememberMessageId(message.id);

    // Save own SOS to database
    await _storage.insertMessage(message);

    // Broadcast to all connected devices
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
    _locationBroadcastTimer?.cancel();
    _locationBroadcastTimer = null;

    _isRunning = false;
    meshError = null;
    discoveredDevices.clear();
    connectedDevices.clear();
    peerLocations.clear();
    peerLocationsByEndpoint.clear();
    notifyListeners();
  }

  void _startLocationHeartbeat() {
    _locationBroadcastTimer?.cancel();
    _locationBroadcastTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!_isRunning || _isFetchingLocation) return;
      try {
        await startLocationBroadcast();
      } catch (_) {}
    });
  }

  /// Gets current GPS fix, stores it as [myLocation], and broadcasts to peers.
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
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
          ),
        ).timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('GPS get position failed, proceeding with 0/0: $e');
      }

      myLocation = LocationUpdate(
        userId: userName,
        userName: userName,
        latitude: position?.latitude ?? 0.0,
        longitude: position?.longitude ?? 0.0,
        timestamp: DateTime.now(),
        isSOS: myTriageStatus == TriageStatus.sos,
        triageStatus: myTriageStatus,
      );
      notifyListeners();

      // Broadcast to all connected peers
      final payload = Constants.LOC_PREFIX + myLocation!.toJson();
      final bytes = Uint8List.fromList(utf8.encode(payload));
      for (final device in connectedDevices) {
        await _nearby.sendBytesPayload(device.id, bytes);
      }
      debugPrint('Location broadcast: ${position?.latitude ?? 0.0}, ${position?.longitude ?? 0.0}');
    } catch (e) {
      debugPrint('Error broadcasting location: $e');
    } finally {
      _isFetchingLocation = false;
    }
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

  // ── Resource broadcast ────────────────────────────────────────────────────

  /// Send raw bytes to a specific peer (used by rescue bridge for census dumps).
  Future<void> sendBytesToPeer(String peerId, Uint8List bytes) async {
    await _nearby.sendBytesPayload(peerId, bytes);
  }

  /// Broadcast a resource offer or need to all connected peers.
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

    // Relay to other peers
    final relayed = Uint8List.fromList(utf8.encode(Constants.RES_PREFIX + wire));
    for (final d in connectedDevices) {
      if (d.id == fromEndpointId) continue;
      await _nearby.sendBytesPayload(d.id, relayed);
    }
  }

  // ── Roll-call packet handlers ─────────────────────────────────────────────

  void _handleRollCallPacket(String fromEndpointId, String wire) async {
    RollCallPacket pkt;
    try { pkt = RollCallPacket.fromWire(wire); } catch (_) { return; }

    final dedupKey = 'rc:${pkt.id}:${pkt.round}';
    if (_seenRcIds.contains(dedupKey)) return;
    _seenRcIds.add(dedupKey);

    // Am I the coordinator? Then just record — no prompt needed.
    if (activeRollCall?.id == pkt.id) return;

    // Show prompt to user (only on first receive, not relayed ones from myself)
    if (incomingRollCall?.id != pkt.id) {
      incomingRollCall = IncomingRollCall(
        id: pkt.id,
        coordinatorName: pkt.coordinatorName,
        receivedAt: DateTime.now(),
        deadlineSecs: pkt.deadlineSecs,
      );
      notifyListeners();
      // Auto-expire the prompt when the deadline passes
      Timer(Duration(seconds: pkt.deadlineSecs), () {
        if (incomingRollCall?.id == pkt.id) {
          incomingRollCall = null;
          notifyListeners();
        }
      });
    }

    // Relay to other peers (hop-limited)
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

    // If I'm the coordinator for this roll call, update the roster.
    final rc = activeRollCall;
    if (rc != null && rc.id == pkt.rollCallId) {
      final entry = rc.entries[pkt.responderName];
      if (entry != null && entry.status == RollCallEntryStatus.pending) {
        entry.status = RollCallEntryStatusX.fromJson(pkt.status);
        entry.respondedAt = DateTime.now();
        notifyListeners();
      }
    }

    // Relay toward coordinator (hop-limited)
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

// ─── Relay event (for topology visualizer) ────────────────────────────────────

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
