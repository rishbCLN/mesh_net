import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/message.dart';
import '../core/constants.dart';
import 'storage_service.dart';

class NearbyService extends ChangeNotifier {
  final Nearby _nearby = Nearby();
  final StorageService _storage = StorageService();
  final Uuid _uuid = const Uuid();

  String userName = '';
  String get myEndpointId => userName; // Use userName as endpoint ID
  
  List<Device> discoveredDevices = [];
  List<Device> connectedDevices = [];

  Future<void> init(String name) async {
    userName = name;
    
    // Start advertising and discovery simultaneously
    await _startAdvertising();
    await _startDiscovery();
  }

  Future<void> _startAdvertising() async {
    try {
      await _nearby.startAdvertising(
        userName,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: Constants.SERVICE_ID,
      );
    } catch (e) {
      debugPrint('Error starting advertising: $e');
    }
  }

  Future<void> _startDiscovery() async {
    try {
      await _nearby.startDiscovery(
        userName,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: Constants.SERVICE_ID,
      );
    } catch (e) {
      debugPrint('Error starting discovery: $e');
    }
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

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final bytes = payload.bytes;
      if (bytes != null) {
        final String data = String.fromCharCodes(bytes);
        debugPrint('Received message: $data');
        
        try {
          final Map<String, dynamic> json = jsonDecode(data);
          final message = Message(
            id: json['id'] as String,
            senderId: json['senderId'] as String,
            senderName: json['senderName'] as String,
            content: json['content'] as String,
            timestamp: DateTime.parse(json['timestamp'] as String),
            isSOS: json['isSOS'] as bool,
          );
          
          // Save to database
          _storage.insertMessage(message);
          notifyListeners();
        } catch (e) {
          debugPrint('Error parsing message: $e');
        }
      }
    }
  }

  Future<void> sendMessage(String endpointId, String content) async {
    final message = Message(
      id: _uuid.v4(),
      senderId: myEndpointId,
      senderName: userName,
      content: content,
      timestamp: DateTime.now(),
      isSOS: false,
    );

    // Save own message to database
    await _storage.insertMessage(message);

    // Send to endpoint
    final json = jsonEncode({
      'id': message.id,
      'senderId': message.senderId,
      'senderName': message.senderName,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
      'isSOS': message.isSOS,
    });

    await _nearby.sendBytesPayload(endpointId, Uint8List.fromList(json.codeUnits));
    notifyListeners();
  }

  Future<void> broadcastMessage(String content) async {
    final message = Message(
      id: _uuid.v4(),
      senderId: myEndpointId,
      senderName: userName,
      content: content,
      timestamp: DateTime.now(),
      isSOS: false,
    );

    // Save own message to database
    await _storage.insertMessage(message);

    // Broadcast to all connected devices
    final json = jsonEncode({
      'id': message.id,
      'senderId': message.senderId,
      'senderName': message.senderName,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
      'isSOS': message.isSOS,
    });

    final bytes = Uint8List.fromList(json.codeUnits);
    for (var device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }
    
    notifyListeners();
  }

  Future<void> sendSOS(String content) async {
    final sosContent = '${Constants.SOS_PREFIX}$content';
    
    final message = Message(
      id: _uuid.v4(),
      senderId: myEndpointId,
      senderName: userName,
      content: sosContent,
      timestamp: DateTime.now(),
      isSOS: true,
    );

    // Save own SOS to database
    await _storage.insertMessage(message);

    // Broadcast to all connected devices
    final json = jsonEncode({
      'id': message.id,
      'senderId': message.senderId,
      'senderName': message.senderName,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
      'isSOS': true,
    });

    final bytes = Uint8List.fromList(json.codeUnits);
    for (var device in connectedDevices) {
      await _nearby.sendBytesPayload(device.id, bytes);
    }
    
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    await _nearby.stopAllEndpoints();
    
    discoveredDevices.clear();
    connectedDevices.clear();
    notifyListeners();
  }
}
