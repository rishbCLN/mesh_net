import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/gateway_service.dart';

/// Thin bar showing gateway escape status. Sits at the top of the home screen.
class GatewayStatusBar extends StatelessWidget {
  const GatewayStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<GatewayService>(
      builder: (context, gw, _) {
        final color = _statusColor(gw.status);
        final label = _statusLabel(gw.status);
        final icon = _statusIcon(gw.status);

        return GestureDetector(
          onTap: () => _showDetailSheet(context, gw),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(Icons.chevron_right, size: 16, color: color.withValues(alpha: 0.6)),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _statusColor(GatewayStatus status) {
    switch (status) {
      case GatewayStatus.idle:
        return Colors.grey;
      case GatewayStatus.attempting:
        return Colors.amber;
      case GatewayStatus.smsSent:
        return Colors.green;
      case GatewayStatus.internetUploaded:
        return Colors.green;
      case GatewayStatus.rescueHandoff:
        return Colors.blue;
    }
  }

  String _statusLabel(GatewayStatus status) {
    switch (status) {
      case GatewayStatus.idle:
        return 'Gateway: Monitoring for escape channels…';
      case GatewayStatus.attempting:
        return 'Gateway: Attempting to send distress signal…';
      case GatewayStatus.smsSent:
        return 'Gateway: SMS distress signal sent ✓';
      case GatewayStatus.internetUploaded:
        return 'Gateway: Data uploaded to server ✓';
      case GatewayStatus.rescueHandoff:
        return 'Gateway: Rescue team received census ✓';
    }
  }

  IconData _statusIcon(GatewayStatus status) {
    switch (status) {
      case GatewayStatus.idle:
        return Icons.cell_tower;
      case GatewayStatus.attempting:
        return Icons.sync;
      case GatewayStatus.smsSent:
        return Icons.sms_rounded;
      case GatewayStatus.internetUploaded:
        return Icons.cloud_upload_rounded;
      case GatewayStatus.rescueHandoff:
        return Icons.local_hospital_rounded;
    }
  }

  void _showDetailSheet(BuildContext context, GatewayService gw) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _GatewayDetailSheet(gw: gw),
    );
  }
}

class _GatewayDetailSheet extends StatelessWidget {
  final GatewayService gw;
  const _GatewayDetailSheet({required this.gw});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'OutsideWorld Gateway',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Multi-layer system to punch distress signals out of the mesh',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 16),
          // Layer statuses
          _LayerRow(
            icon: Icons.sms_rounded,
            label: 'SMS Burst',
            detail: gw.sms.lastSmsFired != null
                ? 'Last sent: ${_fmtTime(gw.sms.lastSmsFired!)}'
                : gw.sms.emergencyContacts.isEmpty
                    ? 'No contacts configured'
                    : 'Monitoring GSM signal…',
            color: gw.sms.smsSent ? Colors.green : Colors.amber,
          ),
          const SizedBox(height: 8),
          _LayerRow(
            icon: Icons.cloud_upload_rounded,
            label: 'Internet Gateway',
            detail: gw.internet.lastUpload != null
                ? 'Last upload: ${_fmtTime(gw.internet.lastUpload!)}'
                : gw.internet.gatewayUrl.isEmpty
                    ? 'No server URL configured'
                    : 'Watching for connectivity…',
            color: gw.internet.uploadSuccess ? Colors.green : Colors.amber,
          ),
          const SizedBox(height: 8),
          _LayerRow(
            icon: Icons.local_hospital_rounded,
            label: 'Rescue Bridge',
            detail: gw.rescue.handoffsCompleted > 0
                ? '${gw.rescue.handoffsCompleted} handoff(s) complete'
                : 'Waiting for rescue team to join mesh…',
            color: gw.rescue.handoffsCompleted > 0 ? Colors.blue : Colors.grey,
          ),
          const SizedBox(height: 16),
          // Event log
          if (gw.eventLog.isNotEmpty) ...[
            const Text('Event Log',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70)),
            const SizedBox(height: 6),
            Container(
              height: 100,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView(
                reverse: true,
                children: gw.eventLog.reversed
                    .map((e) => Text(e,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54, fontFamily: 'monospace')))
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Force send button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.send_rounded),
              label: const Text('Force Send Now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () {
                gw.hardSOSActivated();
                Navigator.pop(context);
              },
            ),
          ),
          // Settings button
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Configure Gateway'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const GatewaySettingsScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

class _LayerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  final Color color;

  const _LayerRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: color)),
              Text(detail,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Gateway Settings Screen ─────────────────────────────────────────────────

class GatewaySettingsScreen extends StatefulWidget {
  const GatewaySettingsScreen({super.key});

  @override
  State<GatewaySettingsScreen> createState() => _GatewaySettingsScreenState();
}

class _GatewaySettingsScreenState extends State<GatewaySettingsScreen> {
  final _contact1 = TextEditingController();
  final _contact2 = TextEditingController();
  final _contact3 = TextEditingController();
  final _urlController = TextEditingController();
  String _selectedRole = 'survivor';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final contacts = prefs.getStringList('emergency_contacts') ?? [];
    final url = prefs.getString('gateway_url') ?? '';
    final role = prefs.getString('device_role') ?? 'survivor';

    setState(() {
      if (contacts.isNotEmpty) _contact1.text = contacts[0];
      if (contacts.length > 1) _contact2.text = contacts[1];
      if (contacts.length > 2) _contact3.text = contacts[2];
      _urlController.text = url;
      _selectedRole = role;
    });
  }

  Future<void> _save() async {
    final gw = Provider.of<GatewayService>(context, listen: false);
    final contacts = [_contact1.text, _contact2.text, _contact3.text]
        .where((c) => c.trim().isNotEmpty)
        .map((c) => c.trim())
        .toList();

    await gw.saveEmergencyContacts(contacts);
    await gw.saveGatewayUrl(_urlController.text.trim());

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_role', _selectedRole);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gateway settings saved')),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _contact1.dispose();
    _contact2.dispose();
    _contact3.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gateway Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Device Role
          const Text('Device Role',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
            'Rescue / Coordinator devices auto-receive census from survivors.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'survivor', label: Text('Survivor')),
              ButtonSegment(value: 'coordinator', label: Text('Coordinator')),
              ButtonSegment(value: 'rescue', label: Text('Rescue')),
            ],
            selected: {_selectedRole},
            onSelectionChanged: (v) => setState(() => _selectedRole = v.first),
          ),
          const SizedBox(height: 24),

          // SMS Emergency Contacts
          const Text('SMS Emergency Contacts',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
            'Phone numbers to receive SMS distress signals. Android only.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          _PhoneField(controller: _contact1, label: 'Contact 1'),
          const SizedBox(height: 8),
          _PhoneField(controller: _contact2, label: 'Contact 2'),
          const SizedBox(height: 8),
          _PhoneField(controller: _contact3, label: 'Contact 3'),
          const SizedBox(height: 24),

          // Internet Gateway URL
          const Text('Internet Gateway URL',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
            'Server endpoint for opportunistic data uploads. '
            'Uploads happen automatically when any internet is detected.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Gateway URL',
              hintText: 'https://meshalert.example.com/api/gateway',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 32),

          ElevatedButton(
            onPressed: _save,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 52),
              backgroundColor: Colors.deepOrange,
            ),
            child: const Text('Save Settings', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}

class _PhoneField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  const _PhoneField({required this.controller, required this.label});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.phone,
      decoration: InputDecoration(
        labelText: label,
        hintText: '+1234567890',
        prefixIcon: const Icon(Icons.phone),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
