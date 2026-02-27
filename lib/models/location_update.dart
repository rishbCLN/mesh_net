import 'dart:convert';
import 'triage_status.dart';

class LocationUpdate {
  final String userId;
  final String userName;
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final bool isSOS;
  final TriageStatus triageStatus;

  LocationUpdate({
    required this.userId,
    required this.userName,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.isSOS = false,
    this.triageStatus = TriageStatus.ok,
  });

  String toJson() {
    return jsonEncode({
      'userId': userId,
      'userName': userName,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp.toIso8601String(),
      'isSOS': isSOS,
      'triageStatus': triageStatus.jsonValue,
    });
  }

  factory LocationUpdate.fromJson(String source) {
    final Map<String, dynamic> data =
        jsonDecode(source) as Map<String, dynamic>;
    return LocationUpdate(
      userId: data['userId'] as String,
      userName: data['userName'] as String,
      latitude: (data['latitude'] as num).toDouble(),
      longitude: (data['longitude'] as num).toDouble(),
      timestamp: DateTime.parse(data['timestamp'] as String),
      isSOS: (data['isSOS'] as bool?) ?? false,
      triageStatus: TriageStatusX.fromJson(data['triageStatus'] as String?),
    );
  }
}
