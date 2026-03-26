import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/triage_data.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';

/// Chat-style AI triage assistant that walks through the START protocol.
class TriageAssistantScreen extends StatefulWidget {
  const TriageAssistantScreen({super.key});

  @override
  State<TriageAssistantScreen> createState() => _TriageAssistantScreenState();
}

class _TriageAssistantScreenState extends State<TriageAssistantScreen> {
  final List<_ChatEntry> _history = [];
  TriageNode _current = triageDecisionTree;
  bool _finished = false;
  TriageStatus? _finalResult;
  bool _broadcasting = false;

  @override
  void initState() {
    super.initState();
    // Push initial question
    _pushAssistant(_current);
  }

  void _pushAssistant(TriageNode node) {
    _history.add(_ChatEntry(
      text: node.question,
      detail: node.detail,
      isUser: false,
    ));
    if (node.isLeaf) {
      _finished = true;
      _finalResult = node.result;
    }
  }

  void _answer(bool yes) {
    if (_finished) return;
    final label = yes ? _current.yesLabel : _current.noLabel;
    _history.add(_ChatEntry(text: label, isUser: true));

    final next = yes ? _current.onYes : _current.onNo;
    if (next != null) {
      _current = next;
      _pushAssistant(next);
    }
    setState(() {});

    // Haptic feedback on each tap
    HapticFeedback.lightImpact();
  }

  Future<void> _applyResult() async {
    if (_finalResult == null || _broadcasting) return;
    setState(() => _broadcasting = true);

    final service = Provider.of<NearbyService>(context, listen: false);
    await service.setTriageStatus(_finalResult!);

    HapticFeedback.heavyImpact();

    if (mounted) {
      setState(() => _broadcasting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Status set to ${_finalResult!.label} and broadcast to mesh',
          ),
          backgroundColor: _finalResult!.color,
        ),
      );
      Navigator.pop(context);
    }
  }

  void _restart() {
    setState(() {
      _history.clear();
      _current = triageDecisionTree;
      _finished = false;
      _finalResult = null;
    });
    _pushAssistant(_current);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1423),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1423),
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_rounded, color: Colors.cyanAccent, size: 22),
            SizedBox(width: 8),
            Text('AI Triage Assistant',
                style: TextStyle(color: Colors.white)),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          TextButton.icon(
            onPressed: _restart,
            icon: const Icon(Icons.refresh, color: Colors.white54, size: 18),
            label:
                const Text('Restart', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Protocol banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: Colors.cyanAccent.withValues(alpha: 0.06),
            child: const Text(
              'START Protocol • Simple Triage and Rapid Treatment',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.cyanAccent, fontSize: 11, letterSpacing: 0.5),
            ),
          ),

          // Chat history
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _history.length,
              itemBuilder: (context, i) {
                final entry = _history[i];
                return _ChatBubble(entry: entry);
              },
            ),
          ),

          // Action area
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            decoration: BoxDecoration(
              color: const Color(0xFF101828),
              border: Border(
                top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08), width: 1),
              ),
            ),
            child: _finished ? _buildResultActions() : _buildQuestionButtons(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionButtons() {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            label: _current.noLabel,
            color: Colors.redAccent,
            icon: Icons.close_rounded,
            onTap: () => _answer(false),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionButton(
            label: _current.yesLabel,
            color: Colors.greenAccent,
            icon: Icons.check_rounded,
            onTap: () => _answer(true),
          ),
        ),
      ],
    );
  }

  Widget _buildResultActions() {
    final result = _finalResult!;
    final color = result.color;

    return Column(
      children: [
        // Result badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(result.icon, color: color, size: 22),
              const SizedBox(width: 10),
              Text(
                'Result: ${result.label}',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Apply + broadcast button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _broadcasting ? null : _applyResult,
            icon: _broadcasting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.broadcast_on_personal_rounded),
            label: Text(
              _broadcasting
                  ? 'Broadcasting…'
                  : 'Set Status & Broadcast to Mesh',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: result.onColor,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Chat bubble ─────────────────────────────────────────────────────────────

class _ChatEntry {
  final String text;
  final String? detail;
  final bool isUser;

  const _ChatEntry({required this.text, this.detail, required this.isUser});
}

class _ChatBubble extends StatelessWidget {
  final _ChatEntry entry;

  const _ChatBubble({required this.entry});

  @override
  Widget build(BuildContext context) {
    final isUser = entry.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isUser
                ? Colors.blueAccent.withValues(alpha: 0.2)
                : const Color(0xFF1A2440),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
            border: Border.all(
              color: isUser
                  ? Colors.blueAccent.withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.smart_toy_rounded,
                          size: 14, color: Colors.cyanAccent),
                      SizedBox(width: 4),
                      Text(
                        'AI Triage',
                        style: TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              Text(
                entry.text,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isUser ? 14 : 15,
                  fontWeight: isUser ? FontWeight.w500 : FontWeight.w600,
                ),
              ),
              if (entry.detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  entry.detail!,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Action button ───────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
