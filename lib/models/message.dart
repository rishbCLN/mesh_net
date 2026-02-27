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
  })  : hopCount = hopCount,
        // SOS messages always have maxHops forced to 10
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
    );
  }

  Map<String, dynamic> toMap() {
    return {
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
    );
  }

  String toJson() {
    return jsonEncode({
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isSOS': isSOS,
      'hopCount': hopCount,
      'maxHops': maxHops,
      'originId': originId,
    });
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
    );
  }
}
