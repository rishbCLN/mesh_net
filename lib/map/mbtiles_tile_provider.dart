import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

/// Serves map tiles from a bundled .mbtiles file (SQLite database).
/// OFFLINE ONLY — never fetches tiles from the internet under any circumstance.
/// Missing tiles render as solid dark background.
class MBTilesTileProvider extends TileProvider {
  Database? _db;
  bool _initialized = false;
  bool _hasAsset = false;

  /// Copy bundled .mbtiles from assets to documents dir, then open.
  Future<void> initialize() async {
    if (_initialized) return;

    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'region.mbtiles');

    if (!File(dbPath).existsSync()) {
      try {
        final data = await rootBundle.load('assets/maps/region.mbtiles');
        final bytes = data.buffer.asUint8List();
        await File(dbPath).writeAsBytes(bytes, flush: true);
        _hasAsset = true;
      } catch (_) {
        // No bundled asset — dark fallback tiles only, never internet
        _hasAsset = false;
        _initialized = true;
        return;
      }
    } else {
      _hasAsset = true;
    }

    _db = await openDatabase(dbPath, readOnly: true);
    _initialized = true;
  }

  bool get isAvailable => _hasAsset && _db != null;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    if (_db == null) {
      return _DarkFallbackTileProvider();
    }
    return _MBTilesImageProvider(
      db: _db!,
      x: coordinates.x,
      y: coordinates.y,
      z: coordinates.z,
    );
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }
}

class _MBTilesImageProvider extends ImageProvider<_MBTilesImageProvider> {
  final Database db;
  final int x, y, z;

  // MBTiles uses TMS y-axis (flipped from XYZ/slippy standard)
  int get tmsY => (1 << z) - 1 - y;

  const _MBTilesImageProvider({
    required this.db,
    required this.x,
    required this.y,
    required this.z,
  });

  @override
  Future<_MBTilesImageProvider> obtainKey(ImageConfiguration config) async => this;

  @override
  ImageStreamCompleter loadImage(
      _MBTilesImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_loadTile(decode));
  }

  Future<ImageInfo> _loadTile(ImageDecoderCallback decode) async {
    try {
      final result = await db.rawQuery(
        'SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?',
        [z, x, tmsY],
      );

      if (result.isEmpty || result.first['tile_data'] == null) {
        return _darkFallbackTile();
      }

      final tileData = result.first['tile_data'] as Uint8List;
      final buffer = await ImmutableBuffer.fromUint8List(tileData);
      final codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    } catch (_) {
      return _darkFallbackTile();
    }
  }

  /// Returns a solid 256×256 dark tile for missing/errored tiles.
  /// Never fetches from internet — this is the only fallback.
  static Future<ImageInfo> _darkFallbackTile() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0xFF1C1C2E),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(256, 256);
    return ImageInfo(image: image);
  }

  @override
  bool operator ==(Object other) =>
      other is _MBTilesImageProvider &&
      x == other.x &&
      y == other.y &&
      z == other.z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

/// Dark fallback tile provider when no MBTiles database is loaded.
/// Returns solid dark tiles — never makes any network request.
class _DarkFallbackTileProvider extends ImageProvider<_DarkFallbackTileProvider> {
  @override
  Future<_DarkFallbackTileProvider> obtainKey(ImageConfiguration config) async => this;

  @override
  ImageStreamCompleter loadImage(
      _DarkFallbackTileProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_darkTile());
  }

  Future<ImageInfo> _darkTile() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0xFF1C1C2E),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(256, 256);
    return ImageInfo(image: image);
  }

  @override
  bool operator ==(Object other) => other is _DarkFallbackTileProvider;

  @override
  int get hashCode => runtimeType.hashCode;
}
