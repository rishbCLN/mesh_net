import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/nearby_service.dart';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _customMessageController = TextEditingController();
  late AnimationController _pulseController;
  bool _sosSent = false;
  int _deviceCount = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _customMessageController.dispose();
    super.dispose();
  }

  Future<void> _sendSOS() async {
    final nearbyService = Provider.of<NearbyService>(context, listen: false);
    
    String sosMessage = '${nearbyService.userName} NEEDS HELP';
    final customMsg = _customMessageController.text.trim();
    if (customMsg.isNotEmpty) {
      sosMessage += ' - $customMsg';
    }

    await nearbyService.sendSOS(sosMessage);
    
    setState(() {
      _sosSent = true;
      _deviceCount = nearbyService.connectedDevices.length;
    });

    // Reset after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _sosSent = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, nearbyService, child) {
        return Scaffold(
          backgroundColor: Colors.red.shade900,
          appBar: AppBar(
            backgroundColor: Colors.red.shade900,
            title: const Text('Emergency SOS'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Connection status
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: nearbyService.connectedDevices.isEmpty
                          ? Colors.black.withOpacity(0.3)
                          : Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          nearbyService.connectedDevices.isEmpty
                              ? Icons.signal_wifi_off
                              : Icons.signal_wifi_4_bar,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          nearbyService.connectedDevices.isEmpty
                              ? 'No devices connected'
                              : '${nearbyService.connectedDevices.length} device(s) connected',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 60),
                  
                  // Pulsing SOS button
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final scale = 1.0 + (_pulseController.value * 0.1);
                      return Transform.scale(
                        scale: scale,
                        child: GestureDetector(
                          onTap: nearbyService.connectedDevices.isEmpty
                              ? null
                              : _sendSOS,
                          child: Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _sosSent ? Colors.green : Colors.red,
                              boxShadow: [
                                BoxShadow(
                                  color: (_sosSent ? Colors.green : Colors.red)
                                      .withOpacity(0.6),
                                  blurRadius: 30,
                                  spreadRadius: 10,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                _sosSent ? '✓' : 'SOS',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 48,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 40),
                  
                  // Confirmation message
                  if (_sosSent)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'SOS Sent to $_deviceCount device${_deviceCount == 1 ? '' : 's'}!',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else
                    Text(
                      nearbyService.connectedDevices.isEmpty
                          ? 'Connect to devices to send SOS'
                          : 'Tap to send emergency alert',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  const SizedBox(height: 40),
                  
                  // Custom message input
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Optional Details',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _customMessageController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'e.g., Trapped under rubble, 3rd floor',
                            hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.1),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          maxLines: 3,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  
                  // Instructions
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Colors.white70,
                          size: 24,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Your SOS will be broadcast to all connected devices in the mesh network',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
