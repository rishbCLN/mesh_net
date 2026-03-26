import '../services/medical_db_service.dart';
import 'symptom_normalizer.dart';

/// Scores conditions by weighted symptom overlap and returns the top matches.
class ConditionClassifier {
  final MedicalDbService _db;

  /// Cache: conditionId → [{ symptom, weight }]
  Map<int, List<_SymptomWeight>>? _symptomMap;

  /// Cache: conditionId → condition row
  Map<int, Map<String, dynamic>>? _conditionMap;

  ConditionClassifier(this._db);

  /// Given a list of [NormalizedSymptom] from the normalizer, return the
  /// top [limit] matching conditions sorted by descending score.
  Future<List<ClassificationResult>> classify(
    List<NormalizedSymptom> symptoms, {
    int limit = 3,
  }) async {
    await _ensureCache();

    // Aggregate: conditionId → total weighted score
    final scores = <int, double>{};
    final matchedSymptoms = <int, Set<String>>{};

    for (final ns in symptoms) {
      // Direct condition hint from phrase match
      scores[ns.conditionId] =
          (scores[ns.conditionId] ?? 0) + ns.confidence * 2.0;
      matchedSymptoms.putIfAbsent(ns.conditionId, () => {}).add(ns.canonical);

      // Also score every condition that has this canonical symptom
      for (final entry in _symptomMap!.entries) {
        for (final sw in entry.value) {
          if (sw.symptom == ns.canonical) {
            scores[entry.key] =
                (scores[entry.key] ?? 0) + sw.weight * ns.confidence;
            matchedSymptoms.putIfAbsent(entry.key, () => {}).add(ns.canonical);
          }
        }
      }
    }

    if (scores.isEmpty) return [];

    // Normalize scores relative to maximum possible per condition
    final results = <ClassificationResult>[];
    for (final entry in scores.entries) {
      final condId = entry.key;
      final cond = _conditionMap![condId];
      if (cond == null) continue;

      final maxPossible = _symptomMap![condId]
              ?.fold<double>(0, (sum, sw) => sum + sw.weight) ??
          1.0;
      final normalizedScore =
          (entry.value / (maxPossible > 0 ? maxPossible : 1.0))
              .clamp(0.0, 1.0);

      results.add(ClassificationResult(
        conditionId: condId,
        conditionName: cond['name'] as String,
        triage: cond['triage'] as String,
        bodySystem: cond['body_system'] as String? ?? '',
        summary: cond['summary'] as String? ?? '',
        score: normalizedScore,
        matchedSymptoms: matchedSymptoms[condId]?.toList() ?? [],
      ));
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }

  Future<void> _ensureCache() async {
    if (_symptomMap != null) return;

    final symptoms = await _db.query('condition_symptoms');
    _symptomMap = {};
    for (final row in symptoms) {
      final cid = row['condition_id'] as int;
      _symptomMap!.putIfAbsent(cid, () => []).add(_SymptomWeight(
        symptom: row['symptom'] as String,
        weight: (row['weight'] as num).toDouble(),
      ));
    }

    final conditions = await _db.query('conditions');
    _conditionMap = {for (final c in conditions) c['id'] as int: c};
  }
}

class _SymptomWeight {
  final String symptom;
  final double weight;
  _SymptomWeight({required this.symptom, required this.weight});
}

class ClassificationResult {
  final int conditionId;
  final String conditionName;
  final String triage;
  final String bodySystem;
  final String summary;
  final double score;
  final List<String> matchedSymptoms;

  ClassificationResult({
    required this.conditionId,
    required this.conditionName,
    required this.triage,
    required this.bodySystem,
    required this.summary,
    required this.score,
    required this.matchedSymptoms,
  });

  @override
  String toString() =>
      'ClassificationResult($conditionName [$triage], score=${score.toStringAsFixed(2)})';
}
