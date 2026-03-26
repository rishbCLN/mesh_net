import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class MediaMessageService {
  static const _uuid = Uuid();

  // ── Landmark cache ──────────────────────────────────────────────────────
  static List<Map<String, dynamic>>? _landmarks;

  static Future<void> _loadLandmarks() async {
    if (_landmarks != null) return;
    final raw = await rootBundle.loadString('assets/landmarks.json');
    final list = jsonDecode(raw) as List<dynamic>;
    _landmarks = list.cast<Map<String, dynamic>>();
  }

  /// Resolve a human-readable location label from coordinates.
  /// Returns "📍 <landmark>" if within radius, otherwise formatted coords.
  static Future<String> resolveLocationLabel(double lat, double lng) async {
    await _loadLandmarks();
    for (final lm in _landmarks!) {
      final double lmLat = (lm['lat'] as num).toDouble();
      final double lmLng = (lm['lng'] as num).toDouble();
      final double radius = (lm['radiusMeters'] as num).toDouble();
      final double dist = _haversineMeters(lat, lng, lmLat, lmLng);
      if (dist <= radius) {
        return '📍 ${lm['name']}';
      }
    }
    // Format coordinates
    final latDir = lat >= 0 ? 'N' : 'S';
    final lngDir = lng >= 0 ? 'E' : 'W';
    final latStr = lat.abs().toStringAsFixed(4);
    final lngStr = lng.abs().toStringAsFixed(4);
    return '📍 $latStr°$latDir, $lngStr°$lngDir';
  }

  static double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static double _deg2rad(double deg) => deg * (pi / 180);

  // ── Photo compression ───────────────────────────────────────────────────

  /// Compress an image file and return the path to the compressed temp file.
  static Future<String> compressImage(String sourcePath) async {
    final tempDir = await getTemporaryDirectory();
    final targetPath = '${tempDir.path}/${_uuid.v4()}.jpg';
    final result = await FlutterImageCompress.compressAndGetFile(
      sourcePath,
      targetPath,
      quality: 55,
      minWidth: 800,
      minHeight: 800,
      format: CompressFormat.jpeg,
    );
    if (result == null) {
      throw Exception('Image compression failed');
    }
    return result.path;
  }

  /// Build the metadata JSON that precedes a photo file payload.
  static String buildPhotoMetadata({
    required String messageId,
    required String senderName,
    required double senderLat,
    required double senderLng,
    required String fileName,
  }) {
    return jsonEncode({
      'type': 'photo',
      'messageId': messageId,
      'senderName': senderName,
      'senderLat': senderLat,
      'senderLng': senderLng,
      'fileName': fileName,
    });
  }

  /// Build the metadata JSON that precedes an audio file payload.
  static String buildAudioMetadata({
    required String messageId,
    required String senderName,
    required double senderLat,
    required double senderLng,
    required String fileName,
    required int durationSeconds,
  }) {
    return jsonEncode({
      'type': 'audio',
      'messageId': messageId,
      'senderName': senderName,
      'senderLat': senderLat,
      'senderLng': senderLng,
      'fileName': fileName,
      'durationSeconds': durationSeconds,
    });
  }

  /// Ensure the received_media directory exists and return its path.
  static Future<String> getReceivedMediaDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory('${docDir.path}/received_media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir.path;
  }
}
