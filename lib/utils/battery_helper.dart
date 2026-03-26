import 'dart:io';

/// Returns the current battery level as an integer (0-100), or null on failure.
Future<int?> getBatteryLevel() async {
  try {
    if (Platform.isAndroid) {
      final file = File('/sys/class/power_supply/battery/capacity');
      if (await file.exists()) {
        final content = (await file.readAsString()).trim();
        return int.tryParse(content);
      }
    }
  } catch (_) {}
  return null;
}
