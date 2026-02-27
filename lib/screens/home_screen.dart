import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/nearby_service.dart';
import '../services/storage_service.dart';
import '../models/message.dart';
import '../widgets/device_tile.dart';
import 'chat_screen.dart';
import 'sos_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final StorageService _storage = StorageService();
  List<Message> recentMessages = [];
  bool _isInitialized = false;
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

    // Initialize nearby service
    if (mounted) {
      final nearbyService = Provider.of<NearbyService>(context, listen: false);
      await nearbyService.init(userName);
      setState(() {
        _isInitialized = true;
      });
    }

    _loadRecentMessages();
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
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _loadRecentMessages,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
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
                                ...nearbyService.connectedDevices
                                    .map((device) => DeviceTile(device: device)),
                              ...nearbyService.discoveredDevices
                                  .map((device) => DeviceTile(device: device)),
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
                      
                      // Action Buttons
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const ChatScreen(),
                                  ),
                                ).then((_) => _loadRecentMessages());
                              },
                              child: const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                  'Open Chat',
                                  style: TextStyle(fontSize: 16),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                              ),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const SosScreen(),
                                  ),
                                ).then((_) => _loadRecentMessages());
                              },
                              child: const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                  'SOS',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
