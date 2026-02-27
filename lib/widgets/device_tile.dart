import 'package:flutter/material.dart';
import '../models/device.dart';

class DeviceTile extends StatelessWidget {
  final Device device;

  const DeviceTile({
    super.key,
    required this.device,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = device.isConnected ? Colors.green : Colors.amber;
    final statusText = device.isConnected ? 'Connected' : 'Discovered';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: statusColor,
            boxShadow: [
              BoxShadow(
                color: statusColor.withOpacity(0.5),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        title: Text(
          device.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          statusText,
          style: TextStyle(
            color: statusColor,
            fontSize: 12,
          ),
        ),
        trailing: Icon(
          device.isConnected ? Icons.link : Icons.device_hub,
          color: statusColor,
        ),
        onTap: () {
          // For now, just show a toast or snackbar
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${device.name} - $statusText'),
              duration: const Duration(seconds: 1),
            ),
          );
        },
      ),
    );
  }
}
