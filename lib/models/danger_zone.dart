import 'dart:convert';
import 'dart:typed_data';

enum DangerType {
  collapse,
  fire,
  flood,
  gas,
  electrical,
  blocked,
  other,
}

extension DangerTypeX on DangerType {
  String get label {
    switch (this) {
      case DangerType.collapse:   return 'Collapse';
      case DangerType.fire:       return 'Fire';
      case DangerType.flood:      return 'Flood';
      case DangerType.gas:        return 'Gas Leak';
      case DangerType.electrical: return 'Electrical';
      case DangerType.blocked:    return 'Blocked';
      case DangerType.other:      return 'Hazard';
    }
  }
}

class DangerZone {
  final String id;
  final String reportedBy;
  final String reportedByName;
  final double latitude;
  final double longitude;
  final DangerType type;
  final String description;
  final DateTime timestamp;
  final String? imageId;
  Uint8List? imageBytes;
  bool imageReceived;

  DangerZone({
    required this.id,
    required this.reportedBy,
    required this.reportedByName,
    required this.latitude,
    required this.longitude,
    required this.type,
    required this.description,
    required this.timestamp,
    this.imageId,
    this.imageBytes,
    this.imageReceived = false,
  });

  String toPayload() {
    return jsonEncode({
      'id': id,
      'by': reportedBy,
      'name': reportedByName,
      'lat': latitude,
      'lng': longitude,
      'type': type.name,
      'desc': description,
      'time': timestamp.millisecondsSinceEpoch,
      'imgId': imageId,
    });
  }

  factory DangerZone.fromPayload(String payload) {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    return DangerZone(
      id: json['id'] as String,
      reportedBy: json['by'] as String,
      reportedByName: json['name'] as String,
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      type: DangerType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => DangerType.other,
      ),
      description: json['desc'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['time'] as int),
      imageId: json['imgId'] as String?,
      imageReceived: false,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'reported_by': reportedBy,
    'reported_by_name': reportedByName,
    'latitude': latitude,
    'longitude': longitude,
    'type': type.name,
    'description': description,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'image_id': imageId,
    'image_bytes': imageBytes,
  };

  factory DangerZone.fromMap(Map<String, dynamic> map) {
    return DangerZone(
      id: map['id'] as String,
      reportedBy: map['reported_by'] as String,
      reportedByName: map['reported_by_name'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      type: DangerType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => DangerType.other,
      ),
      description: map['description'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      imageId: map['image_id'] as String?,
      imageBytes: map['image_bytes'] as Uint8List?,
      imageReceived: map['image_bytes'] != null,
    );
  }
}
