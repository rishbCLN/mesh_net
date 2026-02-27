import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/location_update.dart';
import '../models/message.dart';
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

  // Location tracking
  LocationUpdate? myLocation;
  final Map<String, LocationUpdate> peerLocations = {};
  bool _isFetchingLocation = false;

  static const _kTimeout = Duration(seconds: 5);
  static const _kMaxRetries = 2;

  Future<void> init(String name) async {
    userName = name;
    meshError = null;
    _isRunning = false;
    notifyListeners();

    // Stop any previous session before (re)starting
    try {
      await _nearby.stopAdvertising();
      await _nearby.stopDiscovery();
    } catch (_) {}

    final advOk = await _startAdvertising();
    final disOk = await _startDiscovery();

    _isRunning = advOk || disOk;

    if (!advOk && !disOk) {
      meshError = 'Could not start mesh (radio error). Tap Retry to try again.';
    } else if (!advOk) {
      meshError = 'Advertising failed — others may not find this device.';
    } else if (!disOk) {
      meshError = 'Discovery failed — this device may not find others.';
    }
    notifyListeners();
  }

  /// Returns true on success, false on any error.
  Future<bool> _startAdvertising() async {
    for (var attempt = 1; attempt <= _kMaxRetries; attempt++) {
      try {
        await _nearby
            .startAdvertising(
              userName,
              Strategy.P2P_CLUSTER,
              onConnectionInitiated: _onConnectionInitiated,
              onConnectionResult: _onConnectionResult,
              onDisconnected: _onDisconnected,
              serviceId: Constants.SERVICE_ID,
            )
            .timeout(_kTimeout);
        debugPrint('Advertising started (attempt $attempt)');
        return true;
      } catch (e) {
        debugPrint('Error starting advertising (attempt $attempt): $e');
        if (attempt < _kMaxRetries) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    return false;
  }

  /// Returns true on success, false on any error.
  Future<bool> _startDiscovery() async {
    for (var attempt = 1; attempt <= _kMaxRetries; attempt++) {
      try {
        await _nearby
            .startDiscovery(
              userName,
              Strategy.P2P_CLUSTER,
              onEndpointFound: _onEndpointFound,
              onEndpointLost: _onEndpointLost,
              serviceId: Constants.SERVICE_ID,
            )
            .timeout(_kTimeout);
        debugPrint('Discovery started (attempt $attempt)');
        return true;
      } catch (e) {
        debugPrint('Error starting discovery (attempt $attempt): $e');
        if (attempt < _kMaxRetries) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
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
        orElse: () => Device(id: endpointId, name: 'Unknown', isConnected: false),
      );
      
      discoveredDevices.removeWhere((d) => d.id == endpointId);
      
      if (!connectedDevices.any((d) => d.id == endpointId)) {
        connectedDevices.add(device.copyWith(isConnected: true));
      }
      
      notifyListeners();
      debugPrint('Connected to ${device.name}. Total connections: ${connectedDevices.length}');
    }
  }

  void _onDisconnected(String endpointId) {
    debugPrint('Disconnected from: $endpointId');
    connectedDevices.removeWhere((d) => d.id == endpointId);
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

    // Handle location update payloads
    if (data.startsWith(Constants.LOC_PREFIX)) {
      try {
        final locJson = data.substring(Constants.LOC_PREFIX.length);
        final loc = LocationUpdate.fromJson(locJson);
        peerLocations[loc.userId] = loc;
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

      if (message.hopCount < message.maxHops) {
        final forwarded = message.copyWith(hopCount: message.hopCount + 1);
        final payloadBytes = Uint8List.fromList(utf8.encode(forwarded.toJson()));

        for (var device in connectedDevices) {
          if (device.id == endpointId) {
            continue; // do not echo back to sender
          }
          await _nearby.sendBytesPayload(device.id, payloadBytes);
        }
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

    _isRunning = false;
    meshError = null;
    discoveredDevices.clear();
    connectedDevices.clear();
    peerLocations.clear();
    notifyListeners();
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

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        throw Exception('GPS timed out — no fix after 15 s');
      });

      myLocation = LocationUpdate(
        userId: userName,
        userName: userName,
        latitude: position.latitude,
        longitude: position.longitude,
        timestamp: DateTime.now(),
      );
      notifyListeners();

      // Broadcast to all connected peers
      final payload = Constants.LOC_PREFIX + myLocation!.toJson();
      final bytes = Uint8List.fromList(utf8.encode(payload));
      for (final device in connectedDevices) {
        await _nearby.sendBytesPayload(device.id, bytes);
      }
      debugPrint('Location broadcast: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      debugPrint('Error broadcasting location: $e');
      rethrow;
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
}
