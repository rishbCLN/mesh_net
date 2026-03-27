import 'dart:io';

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
