import 'dart:convert';

// ─── Status of an individual entry ───────────────────────────────────────────

enum RollCallEntryStatus { pending, safe, needHelp, unknown }

extension RollCallEntryStatusX on RollCallEntryStatus {
  String get label {
    switch (this) {
      case RollCallEntryStatus.pending:  return 'Pending';
      case RollCallEntryStatus.safe:     return 'Safe';
      case RollCallEntryStatus.needHelp: return 'Need Help';
      case RollCallEntryStatus.unknown:  return 'No Response';
    }
  }

  // ⚡ accent colour used in the coordinator roster
  int get colorValue {
    switch (this) {
      case RollCallEntryStatus.pending:  return 0xFFFFB300; // amber
      case RollCallEntryStatus.safe:     return 0xFF43A047; // green
      case RollCallEntryStatus.needHelp: return 0xFFE53935; // red
      case RollCallEntryStatus.unknown:  return 0xFF757575; // grey
    }
  }

  String get jsonValue => name; // 'pending' | 'safe' | 'needHelp' | 'unknown'

  static RollCallEntryStatus fromJson(String? v) {
    switch (v) {
      case 'safe':     return RollCallEntryStatus.safe;
      case 'needHelp': return RollCallEntryStatus.needHelp;
      case 'unknown':  return RollCallEntryStatus.unknown;
      default:         return RollCallEntryStatus.pending;
    }
  }
}

// ─── One row in the coordinator roster ───────────────────────────────────────

class RollCallEntry {
  final String name;
  RollCallEntryStatus status;
  DateTime? respondedAt;

  RollCallEntry({required this.name})
      : status = RollCallEntryStatus.pending;
}

// ─── Live coordinator session ─────────────────────────────────────────────────

class RollCallSession {
  final String id;
  final String coordinatorName;
  final DateTime startedAt;
  final DateTime deadline;
  int round;
  final Map<String, RollCallEntry> entries; // keyed by responder name

  RollCallSession({
    required this.id,
    required this.coordinatorName,
    required this.startedAt,
    required this.deadline,
    this.round = 1,
    Map<String, RollCallEntry>? entries,
  }) : entries = entries ?? {};

  int get total       => entries.length;
  int get safeCount   => entries.values.where((e) => e.status == RollCallEntryStatus.safe).length;
  int get helpCount   => entries.values.where((e) => e.status == RollCallEntryStatus.needHelp).length;
  int get unknownCount=> entries.values.where((e) => e.status == RollCallEntryStatus.unknown).length;
  int get pendingCount=> entries.values.where((e) => e.status == RollCallEntryStatus.pending).length;
  int get responded   => total - pendingCount;
  bool get allResponded => pendingCount == 0;
}

// ─── Incoming roll call (responder side) ─────────────────────────────────────

class IncomingRollCall {
  final String id;
  final String coordinatorName;
  final DateTime receivedAt;
  final int deadlineSecs; // seconds the responder has to reply

  IncomingRollCall({
    required this.id,
    required this.coordinatorName,
    required this.receivedAt,
    required this.deadlineSecs,
  });
}

// ─── Wire-format codec ────────────────────────────────────────────────────────

class RollCallPacket {
  final String id;
  final String coordinatorName;
  final int round;
  final int deadlineSecs;
  final int hops;
  static const int maxHops = 5;

  const RollCallPacket({
    required this.id,
    required this.coordinatorName,
    required this.round,
    required this.deadlineSecs,
    this.hops = 0,
  });

  String toWire() => jsonEncode({
        'id': id,
        'from': coordinatorName,
        'round': round,
        'deadline': deadlineSecs,
        'hops': hops,
      });

  factory RollCallPacket.fromWire(String src) {
    final m = jsonDecode(src) as Map<String, dynamic>;
    return RollCallPacket(
      id: m['id'] as String,
      coordinatorName: m['from'] as String,
      round: (m['round'] as num?)?.toInt() ?? 1,
      deadlineSecs: (m['deadline'] as num?)?.toInt() ?? 60,
      hops: (m['hops'] as num?)?.toInt() ?? 0,
    );
  }

  RollCallPacket withNextHop() => RollCallPacket(
        id: id,
        coordinatorName: coordinatorName,
        round: round,
        deadlineSecs: deadlineSecs,
        hops: hops + 1,
      );
}

class RollCallReplyPacket {
  final String rollCallId;
  final String responderName;
  final String status; // 'safe' | 'needHelp'
  final int hops;
  static const int maxHops = 5;

  const RollCallReplyPacket({
    required this.rollCallId,
    required this.responderName,
    required this.status,
    this.hops = 0,
  });

  String toWire() => jsonEncode({
        'rcId': rollCallId,
        'from': responderName,
        'status': status,
        'hops': hops,
      });

  factory RollCallReplyPacket.fromWire(String src) {
    final m = jsonDecode(src) as Map<String, dynamic>;
    return RollCallReplyPacket(
      rollCallId: m['rcId'] as String,
      responderName: m['from'] as String,
      status: m['status'] as String? ?? 'safe',
      hops: (m['hops'] as num?)?.toInt() ?? 0,
    );
  }

  RollCallReplyPacket withNextHop() => RollCallReplyPacket(
        rollCallId: rollCallId,
        responderName: responderName,
        status: status,
        hops: hops + 1,
      );
}
