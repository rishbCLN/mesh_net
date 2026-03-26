import '../services/medical_db_service.dart';

/// Fetches protocol steps and medications for a given condition.
class ProtocolFetcher {
  final MedicalDbService _db;

  ProtocolFetcher(this._db);

  /// Get ordered protocol steps for a condition.
  Future<List<ProtocolStep>> getProtocol(int conditionId) async {
    final rows = await _db.query(
      'protocols',
      where: 'condition_id = ?',
      whereArgs: [conditionId],
      orderBy: 'step_order ASC',
    );
    return rows
        .map((r) => ProtocolStep(
              stepOrder: r['step_order'] as int,
              title: r['title'] as String,
              detail: r['detail'] as String,
              warning: r['warning'] as String?,
            ))
        .toList();
  }

  /// Get medications for a condition.
  Future<List<Medication>> getMedications(int conditionId) async {
    final rows = await _db.query(
      'medications',
      where: 'condition_id = ?',
      whereArgs: [conditionId],
    );
    return rows
        .map((r) => Medication(
              name: r['name'] as String,
              dose: r['dose'] as String?,
              route: r['route'] as String?,
              notes: r['notes'] as String?,
            ))
        .toList();
  }

  /// Get condition summary.
  Future<Map<String, dynamic>?> getCondition(int conditionId) async {
    final rows = await _db.query(
      'conditions',
      where: 'id = ?',
      whereArgs: [conditionId],
    );
    return rows.isNotEmpty ? rows.first : null;
  }
}

class ProtocolStep {
  final int stepOrder;
  final String title;
  final String detail;
  final String? warning;

  ProtocolStep({
    required this.stepOrder,
    required this.title,
    required this.detail,
    this.warning,
  });
}

class Medication {
  final String name;
  final String? dose;
  final String? route;
  final String? notes;

  Medication({
    required this.name,
    this.dose,
    this.route,
    this.notes,
  });
}
