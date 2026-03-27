import 'dart:convert';
import '../services/medical_db_service.dart';

class DecisionTreeEngine {
  final MedicalDbService _db;

  DecisionTreeEngine(this._db);

  
  Future<TreeNode?> loadTree(int conditionId) async {
    final rows = await _db.query(
      'decision_trees',
      where: 'condition_id = ?',
      whereArgs: [conditionId],
    );
    if (rows.isEmpty) return null;
    final json = jsonDecode(rows.first['tree_json'] as String);
    return _parseNode(json);
  }

  TreeNode _parseNode(Map<String, dynamic> json) {
    if (json.containsKey('outcome')) {
      return TreeOutcome(
        outcome: json['outcome'] as String,
        triage: json['triage'] as String,
      );
    }
    final options = (json['options'] as List)
        .map((o) => TreeOption(
              label: o['label'] as String,
              next: _parseNode(o['next'] as Map<String, dynamic>),
            ))
        .toList();
    return TreeQuestion(
      question: json['question'] as String,
      options: options,
    );
  }
}

abstract class TreeNode {}

class TreeQuestion extends TreeNode {
  final String question;
  final List<TreeOption> options;
  TreeQuestion({required this.question, required this.options});
}

class TreeOption {
  final String label;
  final TreeNode next;
  TreeOption({required this.label, required this.next});
}

class TreeOutcome extends TreeNode {
  final String outcome;
  final String triage;
  TreeOutcome({required this.outcome, required this.triage});
}
