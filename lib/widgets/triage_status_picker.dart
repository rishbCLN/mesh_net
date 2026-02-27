import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';

/// Call this to open the triage bottom-sheet from anywhere.
Future<void> showTriagePicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _TriagePickerSheet(),
  );
}

class _TriagePickerSheet extends StatefulWidget {
  const _TriagePickerSheet();

  @override
  State<_TriagePickerSheet> createState() => _TriagePickerSheetState();
}

class _TriagePickerSheetState extends State<_TriagePickerSheet> {
  bool _saving = false;

  Future<void> _select(TriageStatus status) async {
    if (_saving) return;
    setState(() => _saving = true);
    final service = Provider.of<NearbyService>(context, listen: false);
    await service.setTriageStatus(status);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final current =
        Provider.of<NearbyService>(context, listen: false).myTriageStatus;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Set Your Triage Status',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Broadcasts instantly to all connected devices',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 20),
          ...TriageStatus.values.map(
            (status) => _TriageCard(
              status: status,
              isSelected: status == current,
              saving: _saving,
              onTap: () => _select(status),
            ),
          ),
        ],
      ),
    );
  }
}

class _TriageCard extends StatelessWidget {
  final TriageStatus status;
  final bool isSelected;
  final bool saving;
  final VoidCallback onTap;

  const _TriageCard({
    required this.status,
    required this.isSelected,
    required this.saving,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return GestureDetector(
      onTap: saving ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.25) : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? color : Colors.white12,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
              child: Icon(status.icon, color: status.onColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.label,
                    style: TextStyle(
                      color: isSelected ? color : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.description,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: color, size: 22),
          ],
        ),
      ),
    );
  }
}
