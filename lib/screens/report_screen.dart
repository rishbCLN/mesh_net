import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/resource.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';
import '../services/storage_service.dart';
import '../models/message.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final StorageService _storage = StorageService();
  List<Message> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final msgs = await _storage.getAllMessages();
    if (mounted) {
      setState(() {
        _messages = msgs;
        _loading = false;
      });
    }
  }

  String _generateReportText(NearbyService service) {
    final now = DateTime.now();
    final buf = StringBuffer();

    buf.writeln('═══════════════════════════════════');
    buf.writeln('  MESHALERT — SURVIVOR CENSUS REPORT');
    buf.writeln('═══════════════════════════════════');
    buf.writeln();
    buf.writeln('Generated: ${_fmtDate(now)} ${_fmtTime(now)}');
    buf.writeln('Reporter: ${service.userName}');
    buf.writeln();

    
    final peers = service.peerLocations.values.toList();
    final totalLocated = peers.length + (service.myLocation != null ? 1 : 0);
    buf.writeln('── SURVIVORS LOCATED: $totalLocated ──');
    buf.writeln();

    if (service.myLocation != null) {
      final my = service.myLocation!;
      buf.writeln(
          '  [ME] ${service.userName} — ${service.myTriageStatus.label}');
      buf.writeln(
          '        ${my.latitude.toStringAsFixed(5)}, ${my.longitude.toStringAsFixed(5)}');
    }

    for (final peer in peers) {
      buf.writeln(
          '  ${peer.userName} — ${peer.triageStatus.label}');
      buf.writeln(
          '        ${peer.latitude.toStringAsFixed(5)}, ${peer.longitude.toStringAsFixed(5)}');
    }

    buf.writeln();

    
    buf.writeln('── TRIAGE BREAKDOWN ──');
    buf.writeln();

    final allStatuses = <TriageStatus>[
      service.myTriageStatus,
      ...peers.map((p) => p.triageStatus),
    ];

    for (final status in TriageStatus.values) {
      final count = allStatuses.where((s) => s == status).length;
      buf.writeln(
          '  ${status.label.padRight(10)} : $count');
    }

    buf.writeln();

    
    buf.writeln('── MESH NETWORK ──');
    buf.writeln();
    buf.writeln('  Connected devices: ${service.connectedDevices.length}');
    buf.writeln('  Discovered devices: ${service.discoveredDevices.length}');
    buf.writeln('  Messages routed: ${service.totalMessagesRouted}');
    buf.writeln();

    
    final sosMessages = _messages.where((m) => m.isSOS).toList();
    buf.writeln('── SOS ALERTS: ${sosMessages.length} ──');
    buf.writeln();
    for (final sos in sosMessages) {
      buf.writeln(
          '  [${_fmtTime(sos.timestamp)}] ${sos.senderName}: ${sos.content}');
    }

    if (sosMessages.isEmpty) {
      buf.writeln('  (none)');
    }

    buf.writeln();

    
    final offers = service.peerResources.values.where((r) => r.isOffering).toList();
    final needs = service.peerResources.values.where((r) => !r.isOffering).toList();
    buf.writeln('── RESOURCES ──');
    buf.writeln();
    buf.writeln('  Offered: ${offers.length}');
    for (final r in offers) {
      buf.writeln('    ${r.userName}: ${r.resourceType.label}');
    }
    buf.writeln('  Needed: ${needs.length}');
    for (final r in needs) {
      buf.writeln('    ${r.userName}: ${r.resourceType.label}');
    }

    buf.writeln();
    buf.writeln('── END OF REPORT ──');

    return buf.toString();
  }

  Future<void> _shareReport(String text) async {
    await Share.share(text);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, service, _) {
        if (_loading) {
          return Scaffold(
            backgroundColor: const Color(0xFF0D1423),
            appBar: AppBar(
              backgroundColor: const Color(0xFF0D1423),
              title:
                  const Text('Report', style: TextStyle(color: Colors.white)),
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: const Center(
                child: CircularProgressIndicator(color: Colors.amberAccent)),
          );
        }

        final reportText = _generateReportText(service);
        final peers = service.peerLocations.values.toList();
        final totalLocated =
            peers.length + (service.myLocation != null ? 1 : 0);
        final sosCount = _messages.where((m) => m.isSOS).length;

        final allStatuses = <TriageStatus>[
          service.myTriageStatus,
          ...peers.map((p) => p.triageStatus),
        ];

        return Scaffold(
          backgroundColor: const Color(0xFF0D1423),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0D1423),
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.assessment_rounded,
                    color: Colors.amberAccent, size: 22),
                SizedBox(width: 8),
                Text('Census Report',
                    style: TextStyle(color: Colors.white)),
              ],
            ),
            iconTheme: const IconThemeData(color: Colors.white),
            actions: [
              IconButton(
                onPressed: () => _shareReport(reportText),
                icon: const Icon(Icons.share_rounded, color: Colors.amberAccent),
                tooltip: 'Share Report',
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              
              Row(
                children: [
                  _SummaryCard(
                    label: 'Located',
                    value: '$totalLocated',
                    color: Colors.cyanAccent,
                    icon: Icons.people,
                  ),
                  const SizedBox(width: 10),
                  _SummaryCard(
                    label: 'SOS Alerts',
                    value: '$sosCount',
                    color: Colors.redAccent,
                    icon: Icons.warning_rounded,
                  ),
                  const SizedBox(width: 10),
                  _SummaryCard(
                    label: 'Connected',
                    value: '${service.connectedDevices.length}',
                    color: Colors.greenAccent,
                    icon: Icons.device_hub,
                  ),
                ],
              ),
              const SizedBox(height: 20),

              
              const Text(
                'TRIAGE BREAKDOWN',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              ...TriageStatus.values.map((status) {
                final count =
                    allStatuses.where((s) => s == status).length;
                final fraction =
                    allStatuses.isEmpty ? 0.0 : count / allStatuses.length;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: status.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 70,
                        child: Text(
                          status.label,
                          style: TextStyle(
                            color: status.color,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: fraction,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.06),
                            color: status.color,
                            minHeight: 10,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$count',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              }),

              const SizedBox(height: 24),

              
              const Text(
                'SURVIVOR LOCATIONS',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (service.myLocation != null)
                _SurvivorTile(
                  name: '${service.userName} (You)',
                  status: service.myTriageStatus,
                  lat: service.myLocation!.latitude,
                  lon: service.myLocation!.longitude,
                ),
              ...peers.map((peer) => _SurvivorTile(
                    name: peer.userName,
                    status: peer.triageStatus,
                    lat: peer.latitude,
                    lon: peer.longitude,
                  )),

              const SizedBox(height: 24),

              
              const Text(
                'FULL TEXT REPORT',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF101828),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: SelectableText(
                  reportText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _shareReport(reportText),
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('Share Report'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amberAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SurvivorTile extends StatelessWidget {
  final String name;
  final TriageStatus status;
  final double lat;
  final double lon;

  const _SurvivorTile({
    required this.name,
    required this.status,
    required this.lat,
    required this.lon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A2440),
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: status.color.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(status.icon, color: status.color, size: 18),
        ),
        title: Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: status.color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            status.label,
            style: TextStyle(
              color: status.onColor,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
