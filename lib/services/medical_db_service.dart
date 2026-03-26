import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Read-only service for the bundled medical.db asset.
/// Copies the database from assets on first access.
class MedicalDbService {
  static final MedicalDbService _instance = MedicalDbService._internal();
  factory MedicalDbService() => _instance;
  MedicalDbService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = join(dir.path, 'medical.db');

    // Always copy from assets to ensure latest version
    final data = await rootBundle.load('assets/medical/medical.db');
    final bytes = data.buffer.asUint8List();
    await File(dbPath).writeAsBytes(bytes, flush: true);

    return await openDatabase(dbPath, readOnly: true);
  }

  /// Query wrapper for convenience.
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  }) async {
    final db = await database;
    return db.query(table, where: where, whereArgs: whereArgs, orderBy: orderBy);
  }

  /// Raw query wrapper.
  Future<List<Map<String, dynamic>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) async {
    final db = await database;
    return db.rawQuery(sql, args);
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
