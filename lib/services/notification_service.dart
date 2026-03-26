import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'nearby_service.dart';

/// Handles local notifications for Roll Call and SOS alerts.
/// Roll call notifications include "I'm Safe" and "Need Help" action buttons.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  NearbyService? _nearby;

  static const _rollCallChannelId = 'roll_call_channel';
  static const _sosChannelId = 'sos_channel';

  static const _rollCallNotificationId = 1001;
  static const _sosNotificationId = 1002;

  Future<void> initialize(NearbyService nearby) async {
    _nearby = nearby;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationAction,
    );

    // Request notification permission on Android 13+
    _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  void _onNotificationAction(NotificationResponse response) {
    final actionId = response.actionId;
    if (actionId == null || actionId.isEmpty) return;

    if (actionId == 'roll_call_safe') {
      _nearby?.respondToRollCall('safe');
    } else if (actionId == 'roll_call_help') {
      _nearby?.respondToRollCall('needHelp');
    }
    // Dismiss the notification after action
    _plugin.cancel(_rollCallNotificationId);
  }

  Future<void> showRollCallNotification(String coordinatorName) async {
    const androidDetails = AndroidNotificationDetails(
      _rollCallChannelId,
      'Roll Call',
      channelDescription: 'Roll call alerts from mesh network',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      actions: [
        AndroidNotificationAction(
          'roll_call_safe',
          "I'M SAFE",
          showsUserInterface: false,
        ),
        AndroidNotificationAction(
          'roll_call_help',
          'NEED HELP',
          showsUserInterface: false,
        ),
      ],
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _rollCallNotificationId,
      '📢 Roll Call',
      '$coordinatorName is checking everyone\'s status',
      details,
    );
  }

  Future<void> showSOSNotification(String senderName, String content) async {
    const androidDetails = AndroidNotificationDetails(
      _sosChannelId,
      'SOS Alerts',
      channelDescription: 'Emergency SOS alerts from mesh network',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _sosNotificationId,
      '🚨 SOS ALERT',
      '$senderName needs help! $content',
      details,
    );
  }

  Future<void> cancelRollCallNotification() async {
    await _plugin.cancel(_rollCallNotificationId);
  }

  Future<void> cancelSOSNotification() async {
    await _plugin.cancel(_sosNotificationId);
  }
}
