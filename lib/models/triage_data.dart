

import '../models/triage_status.dart';

class TriageNode {
  final String question;
  final String? detail;        
  final String yesLabel;       
  final String noLabel;        
  final TriageNode? onYes;
  final TriageNode? onNo;
  final TriageStatus? result;  

  const TriageNode({
    required this.question,
    this.detail,
    this.yesLabel = 'Yes',
    this.noLabel = 'No',
    this.onYes,
    this.onNo,
    this.result,
  });

  bool get isLeaf => result != null;
}

final TriageNode triageDecisionTree = TriageNode(
  question: 'Can the person walk?',
  detail: 'If they can stand and move on their own, even with difficulty.',
  yesLabel: 'Can walk',
  noLabel: 'Cannot walk',
  onYes: const TriageNode(
    question: 'The person can walk on their own.',
    detail: 'Walking wounded are classified as having minor injuries.',
    result: TriageStatus.ok,
  ),
  onNo: TriageNode(
    question: 'Is the person breathing?',
    detail: 'Look at their chest for movement. Listen for breath sounds. Feel for air from nose/mouth.',
    yesLabel: 'Breathing',
    noLabel: 'Not breathing',
    onYes: TriageNode(
      question: 'Is their breathing rate more than 30 breaths per minute?',
      detail: 'Count breaths for 15 seconds and multiply by 4. Normal is 12-20/min.',
      yesLabel: 'Fast (>30/min)',
      noLabel: 'Normal rate',
      onYes: const TriageNode(
        question: 'Rapid breathing detected — classified as critical.',
        detail: 'The person needs immediate medical attention due to respiratory distress.',
        result: TriageStatus.critical,
      ),
      onNo: TriageNode(
        question: 'Does the person have a pulse at the wrist?',
        detail: 'Place two fingers on the inside of their wrist, below the thumb. Wait 5-10 seconds.',
        yesLabel: 'Has pulse',
        noLabel: 'No pulse',
        onYes: TriageNode(
          question: 'Can the person follow simple commands?',
          detail: 'Ask them to squeeze your hand, or to blink twice.',
          yesLabel: 'Responds',
          noLabel: 'No response',
          onYes: const TriageNode(
            question: 'Person is responsive with stable breathing and pulse.',
            detail: 'They need medical care but are not in immediate danger.',
            result: TriageStatus.injured,
          ),
          onNo: const TriageNode(
            question: 'Person is unresponsive — classified as critical.',
            detail: 'Altered mental status with breathing present indicates serious injury.',
            result: TriageStatus.critical,
          ),
        ),
        onNo: const TriageNode(
          question: 'No pulse detected — classified as critical/trapped.',
          detail: 'This person needs immediate life-saving intervention.',
          result: TriageStatus.sos,
        ),
      ),
    ),
    onNo: TriageNode(
      question: 'Open their airway: tilt the head back and lift the chin. Are they breathing now?',
      detail: 'Sometimes the airway is just blocked. Gently tilt the head back with one hand on the forehead and lift the chin with the other.',
      yesLabel: 'Now breathing',
      noLabel: 'Still not breathing',
      onYes: const TriageNode(
        question: 'Airway obstruction cleared — classified as critical.',
        detail: 'The person must remain in this position. They need immediate help.',
        result: TriageStatus.critical,
      ),
      onNo: const TriageNode(
        question: 'Person is not breathing even after airway repositioning.',
        detail: 'This is a life-threatening emergency. Mark their location for rescue teams.',
        result: TriageStatus.sos,
      ),
    ),
  ),
);
