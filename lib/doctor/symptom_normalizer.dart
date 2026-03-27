import 'dart:math';
import '../services/medical_db_service.dart';

class SymptomNormalizer {
  final MedicalDbService _db;

  
  List<_PhraseRow>? _phrases;

  SymptomNormalizer(this._db);

  Future<List<NormalizedSymptom>> normalize(String input) async {
    await _ensurePhrases();
    final lower = input.toLowerCase().trim();
    final results = <NormalizedSymptom>[];
    final seen = <String>{};

    
    for (final p in _phrases!) {
      if (p.phrase == lower && seen.add(p.canonical)) {
        results.add(NormalizedSymptom(
          canonical: p.canonical,
          conditionId: p.conditionId,
          confidence: 1.0,
          matchType: 'exact',
        ));
      }
    }

    
    if (results.isEmpty) {
      for (final p in _phrases!) {
        if (lower.contains(p.phrase) || p.phrase.contains(lower)) {
          if (seen.add('${p.conditionId}:${p.canonical}')) {
            final ratio = _longestCommonSubstring(lower, p.phrase) /
                max(lower.length, p.phrase.length);
            results.add(NormalizedSymptom(
              canonical: p.canonical,
              conditionId: p.conditionId,
              confidence: 0.6 + (ratio * 0.3),
              matchType: 'contains',
            ));
          }
        }
      }
    }

    
    if (results.isEmpty) {
      final words = lower.split(RegExp(r'\s+'));
      for (final p in _phrases!) {
        final phraseWords = p.phrase.split(RegExp(r'\s+'));
        double bestScore = 0;
        for (final w in words) {
          for (final pw in phraseWords) {
            final dist = _levenshtein(w, pw);
            final maxLen = max(w.length, pw.length);
            if (maxLen > 0) {
              final score = 1.0 - (dist / maxLen);
              if (score > bestScore) bestScore = score;
            }
          }
        }
        if (bestScore >= 0.6 && seen.add('${p.conditionId}:${p.canonical}')) {
          results.add(NormalizedSymptom(
            canonical: p.canonical,
            conditionId: p.conditionId,
            confidence: bestScore * 0.8,
            matchType: 'fuzzy',
          ));
        }
      }
    }

    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  Future<void> _ensurePhrases() async {
    if (_phrases != null) return;
    final rows = await _db.query('phrases');
    _phrases = rows
        .map((r) => _PhraseRow(
              phrase: (r['phrase'] as String).toLowerCase(),
              conditionId: r['condition_id'] as int,
              canonical: r['canonical'] as String,
            ))
        .toList();
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    List<int> curr = List.filled(b.length + 1, 0);

    for (int i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final temp = prev;
      prev = curr;
      curr = temp;
    }
    return prev[b.length];
  }

  static int _longestCommonSubstring(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    int maxLen = 0;
    final dp = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
          if (dp[i][j] > maxLen) maxLen = dp[i][j];
        }
      }
    }
    return maxLen;
  }
}

class _PhraseRow {
  final String phrase;
  final int conditionId;
  final String canonical;
  _PhraseRow({required this.phrase, required this.conditionId, required this.canonical});
}

class NormalizedSymptom {
  final String canonical;
  final int conditionId;
  final double confidence;
  final String matchType;

  NormalizedSymptom({
    required this.canonical,
    required this.conditionId,
    required this.confidence,
    required this.matchType,
  });

  @override
  String toString() => 'NormalizedSymptom($canonical, cond=$conditionId, conf=${confidence.toStringAsFixed(2)}, $matchType)';
}
