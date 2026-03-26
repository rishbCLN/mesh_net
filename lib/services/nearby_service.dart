import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
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
  StreamSubscription<Position>? _positionStreamSub;
  Position? _lastStreamedPosition;
  double totalDistanceTraveled = 0.0;
  double myHeading = 0.0; // compass heading in degrees from GPS

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
        heading: myHeading,
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

  /// Danger zone service — set by app.dart after Provider initialization.
  DangerZoneService? dangerZoneService;

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

  // ── Connection state machine ────────────────────────────────────────────
  //
  // P2P_CLUSTER race condition: both devices discover each other and both
  // call requestConnection() simultaneously.  The Nearby Connections API
  // will reject one side (STATUS_ALREADY_CONNECTED_TO_ENDPOINT or
  // STATUS_ERROR), leaving the device stuck in "discovered".
  //
  // Fix:  Deterministic initiator selection — only the device whose
  // userName is lexicographically smaller initiates the connection.
  // The other device simply waits; it will receive onConnectionInitiated
  // from the initiator side and auto-accept.
  //
  // Retry with exponential backoff handles transient radio failures.

  final Set<String> _pendingRequests = {};
  final Map<String, int> _retryCount = {};   // endpointId → attempts so far
  final Map<String, String> _endpointNames = {}; // endpointId → name cache
  static const int _kMaxConnRetries = 5;

  void _onEndpointFound(String endpointId, String endpointName, String serviceId) async {
    debugPrint('[MESH] Endpoint found: $endpointName ($endpointId)');

    // Skip if already connected to this endpoint
    if (connectedDevices.any((d) => d.id == endpointId)) {
      debugPrint('[MESH] Already connected to $endpointId, ignoring discovery');
      return;
    }

    // Cache the name for later use
    _endpointNames[endpointId] = endpointName;

    // Add to discovered list if new
    if (!discoveredDevices.any((d) => d.id == endpointId)) {
      discoveredDevices.add(Device(
        id: endpointId,
        name: endpointName,
        isConnected: false,
      ));
      notifyListeners();
    }

    // ── Deterministic initiator: only the "smaller" name initiates ──
    // This prevents both sides from calling requestConnection simultaneously.
    // The "larger" name waits — it will receive onConnectionInitiated from
    // the other side via advertising callbacks.
    if (userName.compareTo(endpointName) > 0) {
      debugPrint('[MESH] Waiting for $endpointName to initiate (they have priority)');
      // Safety net: if the other side never initiates within 8 seconds,
      // we initiate ourselves (covers the case where peer isn't using
      // the same tie-breaking logic or is an older version).
      Future.delayed(const Duration(seconds: 8), () {
        if (!_isRunning) return;
        if (connectedDevices.any((d) => d.id == endpointId)) return;
        if (_pendingRequests.contains(endpointId)) return;
        debugPrint('[MESH] Safety-net: $endpointName did not initiate, we will try');
        _initiateConnection(endpointId);
      });
      return;
    }

    // We are the initiator
    _initiateConnection(endpointId);
  }

  /// Send a requestConnection to [endpointId] with full guards.
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

      // Exponential backoff: 2s, 4s, 8s, 16s, 32s
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

    // Cache name from ConnectionInfo (more reliable than discovery name)
    if (info.endpointName.isNotEmpty) {
      _endpointNames[endpointId] = info.endpointName;
    }

    // Always accept — both initiator and receiver must accept for the
    // connection to complete.
    _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    debugPrint('[MESH] Connection result for $endpointId: ${status.toString()}');
    _pendingRequests.remove(endpointId);

    if (status == Status.CONNECTED) {
      // ── SUCCESS ──────────────────────────────────────────────────
      _retryCount.remove(endpointId);

      // Resolve device name from cache
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

      if (!connectedDevices.any((d) => d.id == endpointId)) {
        connectedDevices.add(device.copyWith(isConnected: true));
      }

      // Share location immediately with newly connected peer
      unawaited(startLocationBroadcast());

      // Notify gateway service
      onPeerConnectedCallback?.call(endpointId, device.name);

      notifyListeners();
      debugPrint('[MESH] Connected to ${device.name}. Total: ${connectedDevices.length}');
    } else {
      // ── REJECTED / ERROR ─────────────────────────────────────────
      final attempts = _retryCount[endpointId] ?? 0;
      _retryCount[endpointId] = attempts + 1;

      if (attempts + 1 >= _kMaxConnRetries) {
        debugPrint('[MESH] Connection to $endpointId permanently failed after ${attempts + 1} attempts');
        _retryCount.remove(endpointId);
        return;
      }

      // Exponential backoff retry
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

    // Move back to discovered so we can reconnect
    if (!discoveredDevices.any((d) => d.id == endpointId)) {
      discoveredDevices.add(Device(
        id: endpointId,
        name: disconnectedDevice.name,
        isConnected: false,
      ));
    }
    notifyListeners();

    // Auto-reconnect after a short delay
    Future.delayed(const Duration(seconds: 2), () {
      if (!_isRunning) return;
      if (connectedDevices.any((d) => d.id == endpointId)) return;
      debugPrint('[MESH] Auto-reconnecting to ${disconnectedDevice.name}');
      _initiateConnection(endpointId);
    });
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

    // Handle danger zone metadata
    if (data.startsWith(Constants.DANGER_PREFIX)) {
      _handleDangerPacket(endpointId, data);
      return;
    }

    // Handle danger zone image chunk
    if (data.startsWith(Constants.DIMG_PREFIX)) {
      _handleDangerImagePacket(endpointId, data);
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
    // Heartbeat: re-broadcast current location every 10 s.
    // Does NOT restart the GPS stream — the stream runs continuously.
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

  /// Gets current GPS fix, stores it as [myLocation], and broadcasts to peers.
  /// Also starts a continuous position stream for live movement tracking.
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

      // Start the position stream immediately — don't wait for getCurrentPosition.
      // This way the map starts receiving live GPS updates right away.
      if (_positionStreamSub == null) {
        _startPositionStream();
      }

      // Show last-known position instantly while waiting for a fresh fix
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

      // Get a fresh fix (high accuracy, 8 s cap — faster than 'best')
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('GPS fresh fix failed: $e');
        // Keep last-known position if fresh fix times out
      }

      if (position != null) {
        _lastStreamedPosition = position;
      }

      // Update heading from GPS
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

        // Persist fresh fix
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('lastLat', position.latitude);
          await prefs.setDouble('lastLng', position.longitude);
        } catch (_) {}
      }

      // Broadcast to peers
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

  /// Subscribes to continuous GPS updates.
  ///
  /// Android: requests 1-second intervals so updates arrive within ~2 s of movement.
  /// distanceFilter 3 m: OS-level noise gate — no callback if the fix only
  /// jumped 1-2 m (GPS atmospheric jitter when stationary).
  ///
  /// Speed gate: GPS velocity is far more reliable than position for detecting
  /// real movement. If position.speed < 0.4 m/s (slow walk threshold) AND speed
  /// data is available (>= 0), we treat the callback as noise — the device has
  /// not actually moved — so we skip the position update and distance accumulation.
  /// Heading is always updated (compass bearing is unrelated to speed).
  double _distSinceLastSave = 0.0;

  void _startPositionStream() {
    _positionStreamSub?.cancel();

    // Request 1-second update interval on Android for fast responsiveness.
    // On iOS the OS controls the interval; distanceFilter alone is sufficient.
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
        // ── Always update heading (rotation is valid when stationary) ──
        if (position.heading >= 0) {
          myHeading = position.heading;
        }

        // ── Speed gate: skip if GPS shows we are not actually moving ──
        // position.speed >= 0 means the platform provided speed data.
        // Below 0.4 m/s (~1.4 km/h) with valid speed = stationary GPS drift.
        final bool speedAvailable = position.speed >= 0;
        final bool reallyMoving = !speedAvailable || position.speed >= 0.4;

        if (!reallyMoving) {
          // Device is stationary — update heading only, don't move the marker
          notifyListeners();
          return;
        }

        // ── Real movement: accumulate distance and update marker ──
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

        // Persist to SharedPreferences only every 50 m (debounced)
        if (_distSinceLastSave >= 50.0) {
          _distSinceLastSave = 0.0;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble('lastLat', position.latitude);
            await prefs.setDouble('lastLng', position.longitude);
          } catch (_) {}
        }

        // Update local state — notifyListeners before async broadcast
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

        // Broadcast movement to connected peers
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

  // ── Danger zone packet handlers ───────────────────────────────────────────

  final Set<String> _seenDangerIds = {};
  final Set<String> _seenDimgChunks = {};

  void _handleDangerPacket(String fromEndpointId, String data) async {
    final payload = data.substring(Constants.DANGER_PREFIX.length);
    // Dedup by zone id
    String? zoneId;
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      zoneId = json['id'] as String?;
    } catch (_) {
      return;
    }
    if (zoneId == null || _seenDangerIds.contains(zoneId)) return;
    _seenDangerIds.add(zoneId);

    // Forward to DangerZoneService
    dangerZoneService?.handleDangerPayload(payload);

    // Relay to other peers
    final relayBytes = Uint8List.fromList(utf8.encode(data));
    for (final d in connectedDevices) {
      if (d.id == fromEndpointId) continue;
      await _nearby.sendBytesPayload(d.id, relayBytes);
    }
  }

  void _handleDangerImagePacket(String fromEndpointId, String data) async {
    final payload = data.substring(Constants.DIMG_PREFIX.length);
    // Dedup by imageId + chunkIndex
    final parts = payload.split('::');
    if (parts.length < 4) return;
    final dedupKey = '${parts[0]}::${parts[1]}';
    if (_seenDimgChunks.contains(dedupKey)) return;
    _seenDimgChunks.add(dedupKey);

    // Forward to DangerZoneService
    dangerZoneService?.handleImageChunk(payload);

    // Relay to other peers
    final relayBytes = Uint8List.fromList(utf8.encode(data));
    for (final d in connectedDevices) {
      if (d.id == fromEndpointId) continue;
      await _nearby.sendBytesPayload(d.id, relayBytes);
    }
  }

  /// Broadcast a danger zone (metadata + image chunks) to all peers.
  Future<void> broadcastDangerZone(DangerZoneBroadcast broadcast) async {
    // Broadcast metadata first
    final metaBytes = Uint8List.fromList(
        utf8.encode(Constants.DANGER_PREFIX + broadcast.metadataPayload));
    for (final d in connectedDevices) {
      await _nearby.sendBytesPayload(d.id, metaBytes);
    }

    // Then image chunks with delay to avoid flooding
    for (final chunk in broadcast.imageChunkPayloads) {
      await Future.delayed(const Duration(milliseconds: 50));
      final chunkBytes = Uint8List.fromList(
          utf8.encode(Constants.DIMG_PREFIX + chunk));
      for (final d in connectedDevices) {
        await _nearby.sendBytesPayload(d.id, chunkBytes);
      }
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
