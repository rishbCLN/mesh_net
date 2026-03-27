import 'dart:convert';

class Message {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime timestamp;
  final bool isSOS;
  final int hopCount;
  final int maxHops;
  final String originId;
  final String? imageBase64;
  final String? mediaType;
  final String? mediaPath;
  final String? mediaBase64;
  final double? senderLat;
  final double? senderLng;
  final int? senderBattery;

  Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.timestamp,
    required this.isSOS,
    int hopCount = 0,
    int? maxHops,
    String? originId,
    this.imageBase64,
    this.mediaType,
    this.mediaPath,
    this.mediaBase64,
    this.senderLat,
    this.senderLng,
    this.senderBattery,
  })  : hopCount = hopCount,
        
        maxHops = isSOS ? 10 : (maxHops ?? 5),
        originId = originId ?? id;

  Message copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? content,
    DateTime? timestamp,
    bool? isSOS,
    int? hopCount,
    int? maxHops,
    String? originId,
    String? imageBase64,
    String? mediaType,
    String? mediaPath,
    String? mediaBase64,
    double? senderLat,
    double? senderLng,
    int? senderBattery,
  }) {
    final resolvedIsSOS = isSOS ?? this.isSOS;
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isSOS: resolvedIsSOS,
      hopCount: hopCount ?? this.hopCount,
      maxHops: maxHops ?? this.maxHops,
      originId: originId ?? this.originId,
      imageBase64: imageBase64 ?? this.imageBase64,
      mediaType: mediaType ?? this.mediaType,
      mediaPath: mediaPath ?? this.mediaPath,
      mediaBase64: mediaBase64 ?? this.mediaBase64,
      senderLat: senderLat ?? this.senderLat,
      senderLng: senderLng ?? this.senderLng,
      senderBattery: senderBattery ?? this.senderBattery,
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'content': content,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isSOS': isSOS ? 1 : 0,
      'hopCount': hopCount,
      'maxHops': maxHops,
      'originId': originId,
    };
    if (mediaType != null) map['mediaType'] = mediaType;
    if (mediaPath != null) map['mediaPath'] = mediaPath;
    if (senderLat != null) map['senderLat'] = senderLat;
    if (senderLng != null) map['senderLng'] = senderLng;
    if (senderBattery != null) map['senderBattery'] = senderBattery;
    return map;
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    final dynamic isSOSValue = map['isSOS'];
    final bool parsedIsSOS = isSOSValue is bool ? isSOSValue : (isSOSValue as int) == 1;
    final dynamic timestampValue = map['timestamp'];
    final String parsedId = map['id'] as String;

    return Message(
      id: parsedId,
      senderId: map['senderId'] as String,
      senderName: map['senderName'] as String,
      content: map['content'] as String,
      timestamp: timestampValue is int
          ? DateTime.fromMillisecondsSinceEpoch(timestampValue)
          : DateTime.parse(timestampValue as String),
      isSOS: parsedIsSOS,
      hopCount: (map['hopCount'] as int?) ?? 0,
      maxHops: (map['maxHops'] as int?) ?? (parsedIsSOS ? 10 : 5),
      originId: (map['originId'] as String?) ?? parsedId,
      mediaType: map['mediaType'] as String?,
      mediaPath: map['mediaPath'] as String?,
      senderLat: (map['senderLat'] as num?)?.toDouble(),
      senderLng: (map['senderLng'] as num?)?.toDouble(),
      senderBattery: map['senderBattery'] as int?,
    );
  }

  String toJson() {
    final Map<String, dynamic> map = {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isSOS': isSOS,
      'hopCount': hopCount,
      'maxHops': maxHops,
      'originId': originId,
    };
    if (imageBase64 != null) map['imageBase64'] = imageBase64;
    if (mediaType != null) map['mediaType'] = mediaType;
    if (mediaBase64 != null) map['mediaBase64'] = mediaBase64;
    if (senderLat != null) map['senderLat'] = senderLat;
    if (senderLng != null) map['senderLng'] = senderLng;
    if (senderBattery != null) map['senderBattery'] = senderBattery;
    return jsonEncode(map);
  }

  factory Message.fromJson(String source) {
    final Map<String, dynamic> data = jsonDecode(source) as Map<String, dynamic>;
    return Message(
      id: data['id'] as String,
      senderId: data['senderId'] as String,
      senderName: data['senderName'] as String,
      content: data['content'] as String,
      timestamp: DateTime.parse(data['timestamp'] as String),
      isSOS: data['isSOS'] as bool,
      hopCount: (data['hopCount'] as int?) ?? 0,
      maxHops: (data['maxHops'] as int?) ?? ((data['isSOS'] as bool) ? 10 : 5),
      originId: (data['originId'] as String?) ?? (data['id'] as String),
      imageBase64: data['imageBase64'] as String?,
      mediaType: data['mediaType'] as String?,
      mediaBase64: data['mediaBase64'] as String?,
      senderLat: (data['senderLat'] as num?)?.toDouble(),
      senderLng: (data['senderLng'] as num?)?.toDouble(),
      senderBattery: (data['senderBattery'] as int?),
    );
  }
}
