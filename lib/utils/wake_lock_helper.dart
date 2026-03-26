import 'package:flutter/services.dart';

/// Acquires/releases a partial CPU wake lock via Android PowerManager.
/// This keeps the CPU running when the screen is off so the mesh stays connected.
class WakeLockHelper {
  static const _channel = MethodChannel('com.meshalert/wakelock');

  static Future<void> acquire() async {
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {
      // Fallback: ignore if native side not yet wired
    }
  }

  static Future<void> release() async {
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}
