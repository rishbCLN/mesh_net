import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class CachedNetworkTileProvider extends TileProvider {
  Directory? _cacheDir;

  
  Directory? get cacheDir => _cacheDir;

  Future<void> initialize() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      _cacheDir = Directory(p.join(base.path, 'tile_cache'));
      if (!_cacheDir!.existsSync()) {
        _cacheDir!.createSync(recursive: true);
      }
    } catch (_) {
      _cacheDir = null;
    }
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _CachedTileImageProvider(
      coordinates: coordinates,
      cacheDir: _cacheDir,
    );
  }

  
  
  
  static Future<void> prefetchArea({
    required double lat,
    required double lng,
    required double radiusKm,
    required int minZoom,
    required int maxZoom,
    required Directory? cacheDir,
  }) async {
    if (cacheDir == null) return;

    
    int _toTileX(double lng, int z) =>
        ((lng + 180.0) / 360.0 * (1 << z)).floor();
    int _toTileY(double lat, int z) {
      final latRad = lat * math.pi / 180.0;
      return ((1.0 -
                  math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) /
                      math.pi) /
              2.0 *
              (1 << z))
          .floor();
    }

    
    final latDelta = radiusKm / 111.0;
    final lngDelta = radiusKm / (111.0 * math.cos(lat * math.pi / 180.0));

    final client = http.Client();
    try {
      
      int active = 0;
      final pending = <Future<void>>[];

      for (int z = minZoom; z <= maxZoom; z++) {
        final xMin = _toTileX(lng - lngDelta, z);
        final xMax = _toTileX(lng + lngDelta, z);
        final yMin = _toTileY(lat + latDelta, z); 
        final yMax = _toTileY(lat - latDelta, z);

        for (int x = xMin; x <= xMax; x++) {
          for (int y = yMin; y <= yMax; y++) {
            final file =
                File(p.join(cacheDir.path, '${z}_${x}_$y.png'));
            if (file.existsSync()) continue; 

            final url = 'https://tile.openstreetmap.org/$z/$x/$y.png';
            final fut = () async {
              try {
                final resp = await client.get(
                  Uri.parse(url),
                  headers: {'User-Agent': 'MeshAlert disaster-response/1.0'},
                ).timeout(const Duration(seconds: 10));
                if (resp.statusCode == 200) {
                  await file.writeAsBytes(resp.bodyBytes);
                }
              } catch (_) {}
            }();
            pending.add(fut);

            active++;
            if (active >= 8) {
              await Future.wait(pending);
              pending.clear();
              active = 0;
            }
          }
        }
      }
      if (pending.isNotEmpty) await Future.wait(pending);
    } finally {
      client.close();
    }
  }
}

class _CachedTileImageProvider
    extends ImageProvider<_CachedTileImageProvider> {
  final TileCoordinates coordinates;
  final Directory? cacheDir;

  const _CachedTileImageProvider({
    required this.coordinates,
    required this.cacheDir,
  });

  String get _url =>
      'https://tile.openstreetmap.org/${coordinates.z}/${coordinates.x}/${coordinates.y}.png';

  String get _cacheFile =>
      '${coordinates.z}_${coordinates.x}_${coordinates.y}.png';

  @override
  Future<_CachedTileImageProvider> obtainKey(
          ImageConfiguration config) async =>
      this;

  @override
  ImageStreamCompleter loadImage(
      _CachedTileImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_load(decode));
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    
    if (cacheDir != null) {
      try {
        final file = File(p.join(cacheDir!.path, _cacheFile));
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          return _fromBytes(bytes, decode);
        }
      } catch (_) {}
    }

    
    try {
      final response = await http.get(
        Uri.parse(_url),
        headers: {'User-Agent': 'MeshAlert disaster-response/1.0'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        
        if (cacheDir != null) {
          try {
            await File(p.join(cacheDir!.path, _cacheFile))
                .writeAsBytes(bytes);
          } catch (_) {}
        }
        return _fromBytes(bytes, decode);
      }
    } catch (_) {}

    
    return _darkTile();
  }

  Future<ImageInfo> _fromBytes(
      Uint8List bytes, ImageDecoderCallback decode) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buf);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  static Future<ImageInfo> _darkTile() async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0xFF1C1C2E),
    );
    final img = await rec.endRecording().toImage(256, 256);
    return ImageInfo(image: img);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImageProvider &&
      coordinates.x == other.coordinates.x &&
      coordinates.y == other.coordinates.y &&
      coordinates.z == other.coordinates.z;

  @override
  int get hashCode => Object.hash(coordinates.x, coordinates.y, coordinates.z);
}
