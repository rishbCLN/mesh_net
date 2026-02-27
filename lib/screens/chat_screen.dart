import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/nearby_service.dart';
import '../services/storage_service.dart';
import '../models/message.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final StorageService _storage = StorageService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Message> messages = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    
    // Refresh messages every 2 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadMessages();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final loadedMessages = await _storage.getAllMessages();
    if (mounted) {
      setState(() {
        messages = loadedMessages;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    final nearbyService = Provider.of<NearbyService>(context, listen: false);
    await nearbyService.broadcastMessage(content);
    
    _messageController.clear();
    await _loadMessages();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, nearbyService, child) {
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Chat'),
                Text(
                  '${nearbyService.connectedDevices.length} connected',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              // Messages list
              Expanded(
                child: messages.isEmpty
                    ? const Center(
                        child: Text(
                          'No messages yet. Start chatting!',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          final isMe = message.senderId == nearbyService.myEndpointId;
                          return MessageBubble(
                            message: message,
                            isMe: isMe,
                          );
                        },
                      ),
              ),
              
              // Message input
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(),
                        ),
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _sendMessage,
                      icon: const Icon(Icons.send),
                      color: Colors.deepOrange,
                      iconSize: 28,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
