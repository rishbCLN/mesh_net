import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/doctor_provider.dart';
import '../doctor/condition_classifier.dart';

class DoctorScreen extends StatefulWidget {
  const DoctorScreen({super.key});

  @override
  State<DoctorScreen> createState() => _DoctorScreenState();
}

class _DoctorScreenState extends State<DoctorScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _triageColor(String triage) {
    switch (triage.toUpperCase()) {
      case 'RED':
        return Colors.red;
      case 'YELLOW':
        return Colors.amber;
      case 'GREEN':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DoctorProvider(),
      child: Consumer<DoctorProvider>(
        builder: (context, doctor, _) {
          _scrollToBottom();
          final session = doctor.session;

          return Scaffold(
            appBar: AppBar(
              title: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.medical_services, size: 22),
                  SizedBox(width: 8),
                  Text('Local Doctor'),
                ],
              ),
              actions: [
                if (session.messages.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'New Assessment',
                    onPressed: doctor.reset,
                  ),
              ],
            ),
            body: Column(
              children: [
                
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Colors.orange.shade900.withValues(alpha: 0.3),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'For guidance only — not a substitute for professional medical care. '
                          'Call emergency services if available.',
                          style: TextStyle(fontSize: 11, color: Colors.orange),
                        ),
                      ),
                    ],
                  ),
                ),

                
                Expanded(
                  child: session.messages.isEmpty
                      ? _buildWelcome()
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: session.messages.length +
                              (session.phase == DoctorPhase.conditionSelect ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index < session.messages.length) {
                              return _buildMessageBubble(
                                  session.messages[index], doctor);
                            }
                            
                            return _buildConditionCards(
                                session.classificationResults, doctor);
                          },
                        ),
                ),

                
                if (session.phase == DoctorPhase.input ||
                    session.phase == DoctorPhase.protocol)
                  _buildInputBar(doctor),

                
                if (session.phase == DoctorPhase.classifying)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('Analyzing symptoms...', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.medical_services_outlined,
                size: 64, color: Colors.tealAccent.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            const Text(
              'Local Doctor',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Offline Medical Guidance',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            const Text(
              'Describe your symptoms below and I\'ll help identify\n'
              'possible conditions and treatment steps.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _exampleChip('chest pain and shortness of breath'),
                _exampleChip('bleeding from a wound'),
                _exampleChip('person is choking'),
                _exampleChip('burn on my arm'),
                _exampleChip('snake bite on leg'),
                _exampleChip('high fever and headache'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _exampleChip(String text) {
    return ActionChip(
      label: Text(text, style: const TextStyle(fontSize: 11)),
      backgroundColor: Colors.tealAccent.withValues(alpha: 0.1),
      side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.3)),
      onPressed: () {
        _inputController.text = text;
      },
    );
  }

  Widget _buildMessageBubble(DoctorMessage msg, DoctorProvider doctor) {
    final isUser = msg.isUser;
    final triageColor = msg.triage != null ? _triageColor(msg.triage!) : null;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            
            if (triageColor != null && !isUser)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: triageColor.withValues(alpha: 0.2),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                  border: Border.all(color: triageColor.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      msg.triage == 'RED'
                          ? Icons.emergency
                          : msg.triage == 'YELLOW'
                              ? Icons.warning
                              : Icons.check_circle,
                      color: triageColor,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      msg.triage!,
                      style: TextStyle(
                        color: triageColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

            
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? Colors.tealAccent.withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(triageColor != null && !isUser ? 0 : 14),
                  topRight: Radius.circular(triageColor != null && !isUser ? 0 : 14),
                  bottomLeft: Radius.circular(isUser ? 14 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 14),
                ),
                border: Border.all(
                  color: isUser
                      ? Colors.tealAccent.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.1),
                ),
              ),
              child: Text(
                msg.text,
                style: TextStyle(
                  fontSize: 14,
                  color: isUser ? Colors.tealAccent : Colors.white,
                  height: 1.4,
                ),
              ),
            ),

            
            if (msg.options != null && !isUser)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: msg.options!.asMap().entries.map((entry) {
                    return OutlinedButton(
                      onPressed: () => doctor.answerTreeQuestion(entry.key),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.tealAccent,
                        side: BorderSide(
                          color: Colors.tealAccent.withValues(alpha: 0.4),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      child: Text(entry.value,
                          style: const TextStyle(fontSize: 12)),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConditionCards(
      List<ClassificationResult> results, DoctorProvider doctor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: results.map((r) {
        final color = _triageColor(r.triage);
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          color: color.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: color.withValues(alpha: 0.4)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => doctor.selectCondition(r),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.conditionName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${r.triage} priority • ${(r.score * 100).toInt()}% match',
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                          ),
                        ),
                        if (r.matchedSymptoms.isNotEmpty)
                          Text(
                            'Matched: ${r.matchedSymptoms.join(", ")}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: color),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildInputBar(DoctorProvider doctor) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                textInputAction: TextInputAction.send,
                onSubmitted: (text) {
                  if (text.trim().isNotEmpty) {
                    doctor.submitSymptoms(text.trim());
                    _inputController.clear();
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Describe symptoms...',
                  hintStyle: TextStyle(color: Colors.grey.shade600),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide:
                        BorderSide(color: Colors.tealAccent.withValues(alpha: 0.3)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide:
                        BorderSide(color: Colors.tealAccent.withValues(alpha: 0.2)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: const BorderSide(color: Colors.tealAccent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.tealAccent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.tealAccent),
                onPressed: () {
                  final text = _inputController.text.trim();
                  if (text.isNotEmpty) {
                    doctor.submitSymptoms(text);
                    _inputController.clear();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
