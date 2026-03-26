import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../services/media_message_service.dart';
import '../services/nearby_service.dart';
import '../services/storage_service.dart';
import '../services/voice_message_service.dart';
import '../models/message.dart';
import 'image_viewer_screen.dart';

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
  NearbyService? _nearbyRef;
  final VoiceMessageService _voiceService = VoiceMessageService();
  bool _isRecording = false;
  int _recordingSeconds = 0;
  double _cancelSlide = 0.0;
  final Map<String, AudioPlayer> _audioPlayers = {};
  final Map<String, bool> _audioPlaying = {};
  final Map<String, Duration> _audioPositions = {};
  final Map<String, Duration> _audioDurations = {};
  // Cache for resolved location labels
  final Map<String, String> _locationLabelCache = {};

  @override
  void initState() {
    super.initState();
    _loadMessages();

    // Refresh messages every 2 seconds as fallback
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadMessages();
    });

    // Register a direct listener so new messages appear the instant
    // NearbyService notifies (peer messages, own sent messages, etc.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nearbyRef = Provider.of<NearbyService>(context, listen: false);
      _nearbyRef!.addListener(_onServiceChanged);
    });
  }

  void _onServiceChanged() {
    _loadMessages();
  }

  @override
  void dispose() {
    _nearbyRef?.removeListener(_onServiceChanged);
    _refreshTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _voiceService.dispose();
    for (final player in _audioPlayers.values) {
      player.dispose();
    }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    final nearbyService = Provider.of<NearbyService>(context, listen: false);
    try {
      await nearbyService.broadcastMessage(content);
      _messageController.clear();
    } catch (e) {
      debugPrint('[CHAT] Error sending message: $e');
    }
    await _loadMessages();
  }

  Future<void> _pickAndSendImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.cyanAccent),
              title: const Text('Camera', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.cyanAccent),
              title: const Text('Gallery', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await picker.pickImage(source: source);
    if (picked == null || !mounted) return;

    try {
      final nearbyService = Provider.of<NearbyService>(context, listen: false);
      final compressedPath = await MediaMessageService.compressImage(picked.path);
      final fileName = compressedPath.split('/').last;
      final messageId = const Uuid().v4();
      final lat = nearbyService.myLocation?.latitude ?? 0.0;
      final lng = nearbyService.myLocation?.longitude ?? 0.0;

      final metadataJson = MediaMessageService.buildPhotoMetadata(
        messageId: messageId,
        senderName: nearbyService.userName,
        senderLat: lat,
        senderLng: lng,
        fileName: fileName,
      );

      final localMessage = Message(
        id: messageId,
        senderId: nearbyService.myEndpointId,
        senderName: nearbyService.userName,
        content: '📷 Photo',
        timestamp: DateTime.now(),
        isSOS: false,
        hopCount: 0,
        maxHops: 3,
        originId: messageId,
        mediaType: 'photo',
        mediaPath: compressedPath,
        senderLat: lat,
        senderLng: lng,
      );

      await nearbyService.broadcastMediaFile(
        filePath: compressedPath,
        metadataJson: metadataJson,
        localMessage: localMessage,
      );
    } catch (e) {
      debugPrint('[CHAT] Error sending photo: $e');
    }
    await _loadMessages();
  }

  Future<void> _startVoiceRecording() async {
    setState(() {
      _isRecording = true;
      _recordingSeconds = 0;
      _cancelSlide = 0.0;
    });
    _voiceService.onDurationUpdate = (seconds) {
      if (mounted) setState(() => _recordingSeconds = seconds);
    };
    final path = await _voiceService.startRecording();
    if (!mounted) return;
    setState(() => _isRecording = false);
    if (path == null) return;

    try {
      final nearbyService = Provider.of<NearbyService>(context, listen: false);
      final fileName = path.split('/').last;
      final messageId = const Uuid().v4();
      final lat = nearbyService.myLocation?.latitude ?? 0.0;
      final lng = nearbyService.myLocation?.longitude ?? 0.0;

      final metadataJson = MediaMessageService.buildAudioMetadata(
        messageId: messageId,
        senderName: nearbyService.userName,
        senderLat: lat,
        senderLng: lng,
        fileName: fileName,
        durationSeconds: _recordingSeconds,
      );

      final localMessage = Message(
        id: messageId,
        senderId: nearbyService.myEndpointId,
        senderName: nearbyService.userName,
        content: '🎤 Voice (${_recordingSeconds}s)',
        timestamp: DateTime.now(),
        isSOS: false,
        hopCount: 0,
        maxHops: 3,
        originId: messageId,
        mediaType: 'audio',
        mediaPath: path,
        senderLat: lat,
        senderLng: lng,
      );

      await nearbyService.broadcastMediaFile(
        filePath: path,
        metadataJson: metadataJson,
        localMessage: localMessage,
      );
    } catch (e) {
      debugPrint('[CHAT] Error sending voice message: $e');
    }
    await _loadMessages();
  }

  Future<void> _stopVoiceRecording() async {
    await _voiceService.stopRecording();
  }

  Future<void> _cancelVoiceRecording() async {
    await _voiceService.cancelRecording();
    if (mounted) setState(() => _isRecording = false);
  }

  Future<String> _getLocationLabel(Message message) async {
    if (message.senderLat == null || message.senderLng == null) {
      return '';
    }
    final key = '${message.senderLat!.toStringAsFixed(6)},${message.senderLng!.toStringAsFixed(6)}';
    if (_locationLabelCache.containsKey(key)) {
      return _locationLabelCache[key]!;
    }
    final label = await MediaMessageService.resolveLocationLabel(
      message.senderLat!,
      message.senderLng!,
    );
    _locationLabelCache[key] = label;
    return label;
  }

  void _toggleAudioPlayback(Message message) async {
    final id = message.id;
    final path = message.mediaPath;
    if (path == null) return;

    if (_audioPlaying[id] == true) {
      await _audioPlayers[id]?.pause();
      setState(() => _audioPlaying[id] = false);
      return;
    }

    var player = _audioPlayers[id];
    if (player == null) {
      player = AudioPlayer();
      _audioPlayers[id] = player;
      player.onPositionChanged.listen((pos) {
        if (mounted) setState(() => _audioPositions[id] = pos);
      });
      player.onDurationChanged.listen((dur) {
        if (mounted) setState(() => _audioDurations[id] = dur);
      });
      player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _audioPlaying[id] = false;
            _audioPositions[id] = Duration.zero;
          });
        }
      });
    }

    await player.play(DeviceFileSource(path));
    setState(() => _audioPlaying[id] = true);
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
                          return _buildMessageBubble(message, isMe);
                        },
                      ),
              ),
              
              // Recording overlay
              if (_isRecording)
                GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _cancelSlide += details.delta.dx;
                    });
                    if (_cancelSlide < -100) {
                      _cancelVoiceRecording();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    color: Colors.red.shade900,
                    child: Row(
                      children: [
                        const Icon(Icons.mic, color: Colors.white, size: 24),
                        const SizedBox(width: 12),
                        Text(
                          '0:${_recordingSeconds.toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        const Text(
                          '< Slide to cancel',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: _stopVoiceRecording,
                          icon: const Icon(Icons.stop_circle, color: Colors.white, size: 32),
                        ),
                      ],
                    ),
                  ),
                ),

              // Message input
              if (!_isRecording)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Camera button
                      IconButton(
                        onPressed: _pickAndSendImage,
                        icon: const Icon(Icons.camera_alt_rounded),
                        color: Colors.cyanAccent,
                        iconSize: 26,
                      ),
                      // Mic button
                      IconButton(
                        onPressed: _startVoiceRecording,
                        icon: const Icon(Icons.mic_rounded),
                        color: Colors.cyanAccent,
                        iconSize: 26,
                      ),
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

  Widget _buildMessageBubble(Message message, bool isMe) {
    final bubbleColor = message.isSOS
        ? Colors.red.shade900
        : isMe
            ? Colors.deepOrange
            : const Color(0xFF3C3C3C);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(16),
            border: message.isSOS
                ? Border.all(color: Colors.red, width: 2)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sender name
              Text(
                message.senderName,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: message.isSOS ? Colors.white : Colors.white70,
                ),
              ),
              // Location label
              if (message.senderLat != null && message.senderLng != null)
                FutureBuilder<String>(
                  future: _getLocationLabel(message),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data!.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        snapshot.data!,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 4),
              // SOS indicator
              if (message.isSOS) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.warning, color: Colors.white, size: 16),
                    SizedBox(width: 4),
                    Text(
                      'EMERGENCY',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              // Content: photo, audio, or text
              _buildMessageContent(message),
              const SizedBox(height: 4),
              // Timestamp
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                  if (message.hopCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${message.hopCount} hop${message.hopCount == 1 ? '' : 's'}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageContent(Message message) {
    if (message.mediaType == 'photo' && message.mediaPath != null) {
      return _buildPhotoContent(message);
    }
    if (message.mediaType == 'audio' && message.mediaPath != null) {
      return _buildAudioContent(message);
    }
    // Default: text content (including legacy imageBase64)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.imageBase64 != null && message.imageBase64!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                base64Decode(message.imageBase64!),
                fit: BoxFit.cover,
                width: double.infinity,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image, color: Colors.white54, size: 20),
                      SizedBox(width: 6),
                      Text('Image failed to load',
                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Text(
          message.content,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ],
    );
  }

  Widget _buildPhotoContent(Message message) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(imagePath: message.mediaPath!),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 180,
          width: double.infinity,
          child: Image.file(
            File(message.mediaPath!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAudioContent(Message message) {
    final id = message.id;
    final isPlaying = _audioPlaying[id] == true;
    final position = _audioPositions[id] ?? Duration.zero;
    final duration = _audioDurations[id] ?? const Duration(seconds: 1);
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    // Parse duration from content text like "🎤 Voice (30s)"
    final durationMatch = RegExp(r'\((\d+)s\)').firstMatch(message.content);
    final displayDuration = durationMatch != null
        ? '${int.parse(durationMatch.group(1)!) ~/ 60}:${(int.parse(durationMatch.group(1)!) % 60).toString().padLeft(2, '0')}'
        : '0:00';

    return Row(
      children: [
        IconButton(
          onPressed: () => _toggleAudioPlayback(message),
          icon: Icon(
            isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
            color: Colors.white,
            size: 36,
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
            minHeight: 4,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          displayDuration,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
