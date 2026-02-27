import 'package:flutter/material.dart';
import '../models/device.dart';
import '../models/triage_status.dart';

class DeviceTile extends StatelessWidget {
  final Device device;

  /// Optional triage status received via location broadcast from this peer.
  final TriageStatus? triageStatus;

  const DeviceTile({
    super.key,
    required this.device,
    this.triageStatus,
  });

  @override
  Widget build(BuildContext context) {
    final connectionColor = device.isConnected ? Colors.green : Colors.amber;
    final statusText = device.isConnected ? 'Connected' : 'Discovered';
    final triage = triageStatus;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connectionColor,
            boxShadow: [
              BoxShadow(
                color: connectionColor.withOpacity(0.5),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        title: Text(
          device.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          statusText,
          style: TextStyle(color: connectionColor, fontSize: 12),
        ),
        trailing: triage != null
            ? _TriageBadge(status: triage)
            : Icon(
                device.isConnected ? Icons.link : Icons.device_hub,
                color: connectionColor,
              ),
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                triage != null
                    ? '${device.name} — ${triage.label}: ${triage.description}'
                    : '${device.name} — $statusText',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
    );
  }
}

class _TriageBadge extends StatelessWidget {
  final TriageStatus status;

  const _TriageBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: status.color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 14, color: status.onColor),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: TextStyle(
              color: status.onColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
