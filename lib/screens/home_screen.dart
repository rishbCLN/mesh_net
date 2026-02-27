import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';
import '../services/storage_service.dart';
import '../models/message.dart';
import '../widgets/device_tile.dart';
import '../widgets/triage_status_picker.dart';
import 'chat_screen.dart';
import 'map_screen.dart';
import 'sos_screen.dart';
import 'topology_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final StorageService _storage = StorageService();
  List<Message> recentMessages = [];
  bool _isInitialized = false;
  bool _meshRetrying = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    
    _initializeApp();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    // Request all required runtime permissions before starting mesh services
    await _requestNearbyPermissions();

    final prefs = await SharedPreferences.getInstance();
    String? userName = prefs.getString('userName');

    if (userName == null || userName.isEmpty) {
      // Prompt for username
      userName = await _showNameDialog();
      if (userName != null && userName.isNotEmpty) {
        await prefs.setString('userName', userName);
      } else {
        userName = 'User${DateTime.now().millisecondsSinceEpoch % 1000}';
        await prefs.setString('userName', userName);
      }
    }

    // Fire mesh init in the background — UI should not wait for it
    if (mounted) {
      final nearbyService = Provider.of<NearbyService>(context, listen: false);
      // Do NOT await — set initialized immediately so the screen loads
      nearbyService.init(userName).catchError((e) {
        debugPrint('NearbyService init error: $e');
      });
      setState(() {
        _isInitialized = true;
      });
    }

    _loadRecentMessages();
  }

  Future<void> _retryMesh() async {
    setState(() => _meshRetrying = true);
    final nearbyService = Provider.of<NearbyService>(context, listen: false);
    try {
      await nearbyService.init(nearbyService.userName);
    } catch (e) {
      debugPrint('Mesh retry error: $e');
    } finally {
      if (mounted) setState(() => _meshRetrying = false);
    }
  }

  Future<void> _requestNearbyPermissions() async {
    // Request Location and Nearby WiFi permissions for mesh networking
    final permissions = [
      Permission.location,
      Permission.nearbyWifiDevices,
    ];

    final statuses = await permissions.request();

    final anyPermanentlyDenied = statuses.values
        .any((s) => s.isPermanentlyDenied);
    final anyDenied = statuses.values
        .any((s) => s.isDenied || s.isPermanentlyDenied);

    if (anyDenied && mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Permissions Required'),
          content: const Text(
            'MeshAlert needs Location and Nearby Wi-Fi permissions '
            'to discover and communicate with devices around you.\n\n'
            'Without these permissions the mesh network will not work.',
          ),
          actions: [
            if (anyPermanentlyDenied)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(anyPermanentlyDenied ? 'Cancel' : 'OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<String?> _showNameDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter Your Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Your name',
            labelText: 'Name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadRecentMessages() async {
    final messages = await _storage.getAllMessages();
    if (mounted) {
      setState(() {
        recentMessages = messages.reversed.take(5).toList();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, nearbyService, child) {
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('MeshAlert '),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Opacity(
                      opacity: 0.5 + (_pulseController.value * 0.5),
                      child: const Text(
                        '🔴',
                        style: TextStyle(fontSize: 20),
                      ),
                    );
                  },
                ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: nearbyService.connectedDevices.isEmpty
                          ? Colors.red.withOpacity(0.2)
                          : Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${nearbyService.connectedDevices.length} connected',
                      style: TextStyle(
                        color: nearbyService.connectedDevices.isEmpty
                            ? Colors.red
                            : Colors.green,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: !_isInitialized
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Starting mesh services…',
                          style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadRecentMessages,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Mesh error / retry banner
                      if (nearbyService.meshError != null)
                        Card(
                          color: Colors.orange.shade100,
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.warning_amber_rounded,
                                        color: Colors.orange),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Mesh Unavailable',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(nearbyService.meshError!,
                                    style: const TextStyle(fontSize: 13)),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: _meshRetrying
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : TextButton.icon(
                                          onPressed: _retryMesh,
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('Retry'),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // ── My Triage Status ──────────────────────────────
                      _MyStatusCard(service: nearbyService),
                      const SizedBox(height: 16),

                      // Nearby Devices Section
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Nearby Devices',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (nearbyService.discoveredDevices.isEmpty &&
                                  nearbyService.connectedDevices.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Center(
                                    child: Text(
                                      'Searching for devices...',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  ),
                                )
                              else
                                ...nearbyService.connectedDevices.map(
                                  (device) => DeviceTile(
                                    device: device,
                                    triageStatus: nearbyService
                                        .peerLocations[device.name]
                                        ?.triageStatus,
                                  ),
                                ),
                              ...nearbyService.discoveredDevices.map(
                                (device) => DeviceTile(
                                  device: device,
                                  triageStatus: nearbyService
                                      .peerLocations[device.name]
                                      ?.triageStatus,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      // Recent Messages Section
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Recent Messages',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (recentMessages.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Center(
                                    child: Text(
                                      'No messages yet',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  ),
                                )
                              else
                                ...recentMessages.map((msg) => ListTile(
                                      leading: Icon(
                                        msg.isSOS ? Icons.warning : Icons.message,
                                        color: msg.isSOS ? Colors.red : Colors.deepOrange,
                                      ),
                                      title: Text(
                                        msg.senderName,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: msg.isSOS ? Colors.red : null,
                                        ),
                                      ),
                                      subtitle: Text(
                                        msg.content,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: Text(
                                        '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    )),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Map + Chat side by side
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.map_outlined),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const MapScreen(),
                                  ),
                                );
                              },
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              label: const Text('Map', style: TextStyle(fontSize: 16)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.chat_bubble_outline),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const ChatScreen(),
                                  ),
                                ).then((_) => _loadRecentMessages());
                              },
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              label: const Text('Chat', style: TextStyle(fontSize: 16)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Network topology button (full width)
                      ElevatedButton.icon(
                        icon: const Icon(Icons.device_hub_rounded),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const TopologyScreen(),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 52),
                          backgroundColor: const Color(0xFF10102A),
                          foregroundColor: Colors.cyanAccent,
                          side: const BorderSide(color: Colors.cyanAccent, width: 1),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        label: const Text(
                          'Mesh Network',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 80), // space so content isn't hidden behind SOS bar
                    ],
                  ),
                ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final glow = _pulseController.value;
                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withOpacity(0.3 + glow * 0.4),
                          blurRadius: 12 + glow * 16,
                          spreadRadius: 2 + glow * 4,
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.emergency, size: 28, color: Colors.white),
                      label: const Text(
                        'SOS',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        minimumSize: const Size(double.infinity, 60),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const SosScreen(),
                          ),
                        ).then((_) => _loadRecentMessages());
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── My Status card ────────────────────────────────────────────────────────────

class _MyStatusCard extends StatelessWidget {
  final NearbyService service;

  const _MyStatusCard({required this.service});

  @override
  Widget build(BuildContext context) {
    final status = service.myTriageStatus;
    final color = status.color;

    return GestureDetector(
      onTap: () => showTriagePicker(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.6), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(status.icon, color: status.onColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'My Status',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    status.description,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                Icon(Icons.edit_rounded, size: 16, color: color.withOpacity(0.7)),
                const SizedBox(height: 2),
                Text(
                  'Change',
                  style: TextStyle(fontSize: 10, color: color.withOpacity(0.7)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
