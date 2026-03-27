import 'dart:convert';
import 'dart:typed_data';

class DangerImageService {
  static const int _chunkSize = 512;

  
  
  
  

  
  
  static List<String> chunkImage(String imageId, Uint8List imageBytes) {
    final base64Full = base64Encode(imageBytes);
    final chunks = <String>[];
    final totalChunks = (base64Full.length / _chunkSize).ceil();

    for (int i = 0; i < base64Full.length; i += _chunkSize) {
      final end = (i + _chunkSize < base64Full.length)
          ? i + _chunkSize
          : base64Full.length;
      final chunk = base64Full.substring(i, end);
      chunks.add('$imageId::${chunks.length}::$totalChunks::$chunk');
    }

    return chunks;
  }

  
  static Uint8List? reassembleChunks(
    int totalChunks,
    Map<int, String> chunks,
  ) {
    if (chunks.length != totalChunks) return null;

    final buffer = StringBuffer();
    for (int i = 0; i < totalChunks; i++) {
      if (!chunks.containsKey(i)) return null;
      buffer.write(chunks[i]);
    }

    try {
      return base64Decode(buffer.toString());
    } catch (_) {
      return null;
    }
  }
}
