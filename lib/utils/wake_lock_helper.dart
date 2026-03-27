import 'package:flutter/services.dart';

class WakeLockHelper {
  static const _channel = MethodChannel('com.meshalert/wakelock');

  static Future<void> acquire() async {
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {
      
    }
  }

  static Future<void> release() async {
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}
