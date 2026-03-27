import 'package:flutter/foundation.dart';
import '../services/medical_db_service.dart';
import '../doctor/symptom_normalizer.dart';
import '../doctor/condition_classifier.dart';
import '../doctor/decision_tree_engine.dart';
import '../doctor/protocol_fetcher.dart';

class DoctorProvider extends ChangeNotifier {
  final MedicalDbService _db = MedicalDbService();
  late final SymptomNormalizer _normalizer;
  late final ConditionClassifier _classifier;
  late final DecisionTreeEngine _treeEngine;
  late final ProtocolFetcher _protocolFetcher;

  DoctorSession _session = DoctorSession();
  DoctorSession get session => _session;

  DoctorProvider() {
    _normalizer = SymptomNormalizer(_db);
    _classifier = ConditionClassifier(_db);
    _treeEngine = DecisionTreeEngine(_db);
    _protocolFetcher = ProtocolFetcher(_db);
  }

  
  void reset() {
    _session = DoctorSession();
    notifyListeners();
  }

  
  Future<void> submitSymptoms(String text) async {
    _session = _session.copyWith(
      phase: DoctorPhase.classifying,
      userInput: text,
      messages: [
        ..._session.messages,
        DoctorMessage(text: text, isUser: true),
      ],
    );
    notifyListeners();

    try {
      final normalized = await _normalizer.normalize(text);
      if (normalized.isEmpty) {
        _session = _session.copyWith(
          phase: DoctorPhase.input,
          messages: [
            ..._session.messages,
            DoctorMessage(
              text: 'I couldn\'t match those symptoms. Try describing what you feel '
                  'more specifically (e.g. "chest pain", "difficulty breathing", '
                  '"bleeding from arm").',
              isUser: false,
            ),
          ],
        );
        notifyListeners();
        return;
      }

      final results = await _classifier.classify(normalized, limit: 3);
      if (results.isEmpty) {
        _session = _session.copyWith(
          phase: DoctorPhase.input,
          messages: [
            ..._session.messages,
            DoctorMessage(
              text: 'No conditions matched. Please describe your symptoms differently.',
              isUser: false,
            ),
          ],
        );
        notifyListeners();
        return;
      }

      _session = _session.copyWith(
        phase: DoctorPhase.conditionSelect,
        classificationResults: results,
        messages: [
          ..._session.messages,
          DoctorMessage(
            text: 'Based on your symptoms, here are the most likely conditions:',
            isUser: false,
          ),
        ],
      );
      notifyListeners();
    } catch (e) {
      _session = _session.copyWith(
        phase: DoctorPhase.input,
        messages: [
          ..._session.messages,
          DoctorMessage(text: 'Error: $e', isUser: false),
        ],
      );
      notifyListeners();
    }
  }

  
  Future<void> selectCondition(ClassificationResult result) async {
    _session = _session.copyWith(
      phase: DoctorPhase.treeNavigation,
      selectedCondition: result,
      messages: [
        ..._session.messages,
        DoctorMessage(text: result.conditionName, isUser: true),
      ],
    );
    notifyListeners();

    
    final tree = await _treeEngine.loadTree(result.conditionId);
    if (tree == null || tree is TreeOutcome) {
      
      await _showProtocol(result.conditionId, result.triage);
      return;
    }

    _session = _session.copyWith(
      currentTreeNode: tree,
      messages: [
        ..._session.messages,
        DoctorMessage(
          text: (tree as TreeQuestion).question,
          isUser: false,
          options: tree.options.map((o) => o.label).toList(),
        ),
      ],
    );
    notifyListeners();
  }

  
  Future<void> answerTreeQuestion(int optionIndex) async {
    final current = _session.currentTreeNode;
    if (current == null || current is! TreeQuestion) return;

    final option = current.options[optionIndex];
    _session = _session.copyWith(
      messages: [
        ..._session.messages,
        DoctorMessage(text: option.label, isUser: true),
      ],
    );
    notifyListeners();

    final next = option.next;
    if (next is TreeOutcome) {
      
      final triageOverride = next.triage;
      _session = _session.copyWith(
        currentTreeNode: null,
        treeOutcome: next,
        messages: [
          ..._session.messages,
          DoctorMessage(
            text: next.outcome,
            isUser: false,
            triage: triageOverride,
          ),
        ],
      );
      notifyListeners();

      if (_session.selectedCondition != null) {
        await _showProtocol(
          _session.selectedCondition!.conditionId,
          triageOverride,
        );
      }
    } else if (next is TreeQuestion) {
      _session = _session.copyWith(
        currentTreeNode: next,
        messages: [
          ..._session.messages,
          DoctorMessage(
            text: next.question,
            isUser: false,
            options: next.options.map((o) => o.label).toList(),
          ),
        ],
      );
      notifyListeners();
    }
  }

  Future<void> _showProtocol(int conditionId, String triage) async {
    final steps = await _protocolFetcher.getProtocol(conditionId);
    final meds = await _protocolFetcher.getMedications(conditionId);
    final condition = await _protocolFetcher.getCondition(conditionId);

    final messages = <DoctorMessage>[..._session.messages];

    if (condition != null && condition['summary'] != null) {
      messages.add(DoctorMessage(
        text: condition['summary'] as String,
        isUser: false,
        triage: triage,
      ));
    }

    if (steps.isNotEmpty) {
      messages.add(DoctorMessage(
        text: '📋 Treatment Protocol:',
        isUser: false,
        triage: triage,
      ));
      for (final step in steps) {
        String stepText = '${step.stepOrder}. ${step.title}\n${step.detail}';
        if (step.warning != null) {
          stepText += '\n⚠️ ${step.warning}';
        }
        messages.add(DoctorMessage(text: stepText, isUser: false));
      }
    }

    if (meds.isNotEmpty) {
      messages.add(DoctorMessage(
        text: '💊 Medications:',
        isUser: false,
      ));
      for (final med in meds) {
        String medText = '• ${med.name}';
        if (med.dose != null) medText += ' — ${med.dose}';
        if (med.route != null) medText += ' (${med.route})';
        if (med.notes != null) medText += '\n  ${med.notes}';
        messages.add(DoctorMessage(text: medText, isUser: false));
      }
    }

    messages.add(DoctorMessage(
      text: 'Type new symptoms to start another assessment, or tap "New Assessment" to reset.',
      isUser: false,
    ));

    _session = _session.copyWith(
      phase: DoctorPhase.protocol,
      protocolSteps: steps,
      medications: meds,
      messages: messages,
    );
    notifyListeners();
  }
}

enum DoctorPhase { input, classifying, conditionSelect, treeNavigation, protocol }

class DoctorMessage {
  final String text;
  final bool isUser;
  final List<String>? options;
  final String? triage;

  DoctorMessage({
    required this.text,
    required this.isUser,
    this.options,
    this.triage,
  });
}

class DoctorSession {
  final DoctorPhase phase;
  final String? userInput;
  final List<ClassificationResult> classificationResults;
  final ClassificationResult? selectedCondition;
  final TreeNode? currentTreeNode;
  final TreeOutcome? treeOutcome;
  final List<ProtocolStep> protocolSteps;
  final List<Medication> medications;
  final List<DoctorMessage> messages;

  DoctorSession({
    this.phase = DoctorPhase.input,
    this.userInput,
    this.classificationResults = const [],
    this.selectedCondition,
    this.currentTreeNode,
    this.treeOutcome,
    this.protocolSteps = const [],
    this.medications = const [],
    this.messages = const [],
  });

  DoctorSession copyWith({
    DoctorPhase? phase,
    String? userInput,
    List<ClassificationResult>? classificationResults,
    ClassificationResult? selectedCondition,
    TreeNode? currentTreeNode,
    TreeOutcome? treeOutcome,
    List<ProtocolStep>? protocolSteps,
    List<Medication>? medications,
    List<DoctorMessage>? messages,
  }) {
    return DoctorSession(
      phase: phase ?? this.phase,
      userInput: userInput ?? this.userInput,
      classificationResults: classificationResults ?? this.classificationResults,
      selectedCondition: selectedCondition ?? this.selectedCondition,
      currentTreeNode: currentTreeNode ?? this.currentTreeNode,
      treeOutcome: treeOutcome ?? this.treeOutcome,
      protocolSteps: protocolSteps ?? this.protocolSteps,
      medications: medications ?? this.medications,
      messages: messages ?? this.messages,
    );
  }
}
