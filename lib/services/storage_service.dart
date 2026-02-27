import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/message.dart';
import '../core/constants.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await initDB();
    return _database!;
  }

  Future<Database> initDB() async {
    String path = join(await getDatabasesPath(), Constants.DB_NAME);
    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE ${Constants.TABLE_MESSAGES} (
            id TEXT PRIMARY KEY,
            senderId TEXT NOT NULL,
            senderName TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            isSOS INTEGER NOT NULL,
            hopCount INTEGER NOT NULL DEFAULT 0,
            maxHops INTEGER NOT NULL DEFAULT 5
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE ${Constants.TABLE_MESSAGES} ADD COLUMN hopCount INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE ${Constants.TABLE_MESSAGES} ADD COLUMN maxHops INTEGER NOT NULL DEFAULT 5');
        }
      },
    );
  }

  Future<void> insertMessage(Message message) async {
    final db = await database;
    await db.insert(
      Constants.TABLE_MESSAGES,
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Message>> getAllMessages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      Constants.TABLE_MESSAGES,
      orderBy: 'timestamp ASC',
    );
    return List.generate(maps.length, (i) => Message.fromMap(maps[i]));
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete(Constants.TABLE_MESSAGES);
  }
}
