import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

class VoiceMessageService {
  static const _uuid = Uuid();
  static const int maxDurationSeconds = 60;

  final AudioRecorder _recorder = AudioRecorder();
  Timer? _durationTimer;
  int _elapsedSeconds = 0;
  bool _isRecording = false;
  Completer<String?>? _recordingCompleter;

  bool get isRecording => _isRecording;
  int get elapsedSeconds => _elapsedSeconds;

  
  void Function(int seconds)? onDurationUpdate;

  
  
  Future<String?> startRecording() async {
    if (_isRecording) return null;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return null;

    final tempDir = await getTemporaryDirectory();
    final filePath = '${tempDir.path}/${_uuid.v4()}.ogg';

    _elapsedSeconds = 0;
    _isRecording = true;
    _recordingCompleter = Completer<String?>();

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.opus,
        bitRate: 14000,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: filePath,
    );

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _elapsedSeconds++;
      onDurationUpdate?.call(_elapsedSeconds);
      if (_elapsedSeconds >= maxDurationSeconds) {
        stopRecording();
      }
    });

    return _recordingCompleter!.future;
  }

  
  Future<void> stopRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    _durationTimer?.cancel();
    _durationTimer = null;

    final path = await _recorder.stop();
    _recordingCompleter?.complete(path);
    _recordingCompleter = null;
  }

  
  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    _durationTimer?.cancel();
    _durationTimer = null;

    await _recorder.stop();
    _recordingCompleter?.complete(null);
    _recordingCompleter = null;
  }

  void dispose() {
    _durationTimer?.cancel();
    _recorder.dispose();
  }
}
