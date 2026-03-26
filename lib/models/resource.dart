import 'dart:convert';

enum ResourceType {
  water,
  firstAid,
  flashlight,
  blanket,
  food,
  phoneCharger,
}

extension ResourceTypeX on ResourceType {
  String get label {
    switch (this) {
      case ResourceType.water:        return 'Water';
      case ResourceType.firstAid:     return 'First Aid';
      case ResourceType.flashlight:   return 'Flashlight';
      case ResourceType.blanket:      return 'Blanket';
      case ResourceType.food:         return 'Food';
      case ResourceType.phoneCharger: return 'Phone Charger';
    }
  }

  String get emoji {
    switch (this) {
      case ResourceType.water:        return '💧';
      case ResourceType.firstAid:     return '🩹';
      case ResourceType.flashlight:   return '🔦';
      case ResourceType.blanket:      return '🛏️';
      case ResourceType.food:         return '🍞';
      case ResourceType.phoneCharger: return '🔌';
    }
  }

  String get jsonValue => name;

  static ResourceType fromJson(String? value) {
    switch (value) {
      case 'water':        return ResourceType.water;
      case 'firstAid':     return ResourceType.firstAid;
      case 'flashlight':   return ResourceType.flashlight;
      case 'blanket':      return ResourceType.blanket;
      case 'food':         return ResourceType.food;
      case 'phoneCharger': return ResourceType.phoneCharger;
      default:             return ResourceType.water;
    }
  }
}

class ResourceBroadcast {
  final String userId;
  final String userName;
  final ResourceType resourceType;
  final bool isOffering; // true = "I have this", false = "I need this"
  final double latitude;
  final double longitude;
  final DateTime timestamp;

  ResourceBroadcast({
    required this.userId,
    required this.userName,
    required this.resourceType,
    required this.isOffering,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  String toJson() {
    return jsonEncode({
      'userId': userId,
      'userName': userName,
      'resourceType': resourceType.jsonValue,
      'isOffering': isOffering,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp.toIso8601String(),
    });
  }

  factory ResourceBroadcast.fromJson(String source) {
    final Map<String, dynamic> data =
        jsonDecode(source) as Map<String, dynamic>;
    return ResourceBroadcast(
      userId: data['userId'] as String,
      userName: data['userName'] as String,
      resourceType: ResourceTypeX.fromJson(data['resourceType'] as String?),
      isOffering: data['isOffering'] as bool,
      latitude: (data['latitude'] as num).toDouble(),
      longitude: (data['longitude'] as num).toDouble(),
      timestamp: DateTime.parse(data['timestamp'] as String),
    );
  }
}
