import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:telephony/telephony.dart';
import '../models/triage_status.dart';
import 'storage_service.dart';
import 'nearby_service.dart';

class SmsGatewayService {
  final StorageService _storage;
  final NearbyService _nearby;

  List<String> emergencyContacts = [];

  bool _smsSent = false;
  bool get smsSent => _smsSent;
  DateTime? _lastSmsFired;
  DateTime? get lastSmsFired => _lastSmsFired;
  Timer? _signalMonitorTimer;

  static const Duration smsCooldown = Duration(minutes: 10);

  SmsGatewayService({
    required StorageService storage,
    required NearbyService nearby,
  })  : _storage = storage,
        _nearby = nearby;

  /// Begin passive GSM signal monitoring.
  /// Checks every 30 seconds and fires SMS if contacts are configured.
  void startMonitoring() {
    if (!Platform.isAndroid) return; // SMS sending is Android-only
    _signalMonitorTimer?.cancel();
    _signalMonitorTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkAndFireIfReady(),
    );
  }

  void stopMonitoring() {
    _signalMonitorTimer?.cancel();
    _smsSent = false;
  }

  Future<void> _checkAndFireIfReady() async {
    if (emergencyContacts.isEmpty) return;

    // Cooldown guard
    if (_lastSmsFired != null &&
        DateTime.now().difference(_lastSmsFired!) < smsCooldown) {
      return;
    }

    try {
      final telephony = Telephony.instance;
      final bool? permissionGranted = await telephony.requestSmsPermissions;
      if (permissionGranted != true) return;

      final String payload = await _buildSmsPayload();
      if (payload.isEmpty) return;

      for (final contact in emergencyContacts) {
        try {
          await telephony.sendSms(
            to: contact,
            message: payload,
            statusListener: (SendStatus status) {
              if (status == SendStatus.SENT) {
                _lastSmsFired = DateTime.now();
                _smsSent = true;
                debugPrint('[SMS_GATEWAY] SMS sent to $contact');
              }
            },
          );
        } catch (e) {
          debugPrint('[SMS_GATEWAY] SMS failed to $contact: $e');
        }
      }
    } catch (e) {
      debugPrint('[SMS_GATEWAY] Monitoring error: $e');
    }
  }

  /// Build a compact, information-dense SMS payload from mesh state.
  Future<String> _buildSmsPayload() async {
    final allMessages = await _storage.getAllMessages();
    final sosMessages = allMessages.where((m) => m.isSOS).toList();

    // Count triage states from peer location data
    int critical = 0, injured = 0, trapped = 0;
    for (final loc in _nearby.peerLocations.values) {
      switch (loc.triageStatus) {
        case TriageStatus.critical:
          critical++;
          break;
        case TriageStatus.injured:
          injured++;
          break;
        case TriageStatus.sos:
          trapped++;
          break;
        case TriageStatus.ok:
          break;
      }
    }

    final totalSurvivors = _nearby.connectedDevices.length + 1; // +self

    // Get most recent SOS message content
    final recentSos = sosMessages.isNotEmpty
        ? sosMessages.last.content.replaceFirst('SOS::', '').trim()
        : 'No SOS message';

    // Get best available GPS
    final ownLoc = _nearby.myLocation;
    final locationStr = ownLoc != null && ownLoc.latitude != 0.0
        ? '${ownLoc.latitude.toStringAsFixed(4)},${ownLoc.longitude.toStringAsFixed(4)}'
        : 'GPS unavailable';

    final buffer = StringBuffer();
    buffer.writeln('MESHALERT DISTRESS');
    buffer.writeln('Loc:$locationStr');
    buffer.writeln('S:$totalSurvivors C:$critical I:$injured T:$trapped');
    if (recentSos.length > 60) {
      buffer.writeln('"${recentSos.substring(0, 57)}..."');
    } else {
      buffer.writeln('"$recentSos"');
    }
    buffer.write('Auto-MeshAlert');

    return buffer.toString();
  }

  /// Manually trigger SMS burst — e.g. from Hard SOS
  Future<void> forceSend() async {
    _lastSmsFired = null; // Override cooldown
    await _checkAndFireIfReady();
  }

  void setEmergencyContacts(List<String> contacts) {
    emergencyContacts = contacts;
  }

  void dispose() {
    stopMonitoring();
  }
}
