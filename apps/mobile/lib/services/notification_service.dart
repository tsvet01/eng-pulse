import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

/// Background message handler - must be top-level function
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('Background message: ${message.messageId}');
}

class NotificationService {
  static FirebaseMessaging? _messaging;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static bool _firebaseAvailable = false;
  static String? _fcmToken;

  static String? get fcmToken => _fcmToken;
  static bool get isAvailable => _firebaseAvailable;

  /// Backend API endpoint for FCM token registration
  static const String _registerTokenUrl =
      'https://us-central1-tsvet01.cloudfunctions.net/register-token';

  /// Initialize notification service
  /// Call this after Firebase.initializeApp()
  static Future<void> init() async {
    if (_initialized) return;

    try {
      _messaging = FirebaseMessaging.instance;
      _firebaseAvailable = true;

      // Set background message handler
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // Request permission
      await _requestPermission();

      // Initialize local notifications
      await _initLocalNotifications();

      // Get FCM token
      await _getToken();

      // Listen for token refresh
      _messaging!.onTokenRefresh.listen((token) {
        _fcmToken = token;
        debugPrint('FCM Token refreshed');
        _registerTokenWithBackend(token);
      });

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Handle notification taps when app is in background
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Check if app was opened from a notification
      final initialMessage = await _messaging!.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationTap(initialMessage);
      }

      _initialized = true;
      debugPrint('NotificationService initialized');
    } catch (e) {
      debugPrint('Failed to initialize NotificationService: $e');
      _firebaseAvailable = false;
    }
  }

  static Future<void> _requestPermission() async {
    final settings = await _messaging!.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    debugPrint('Notification permission: ${settings.authorizationStatus}');
  }

  static Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
        // Handle notification tap
        debugPrint('Local notification tapped: ${details.payload}');
        if (details.payload != null) {
          _handlePayload(details.payload!);
        }
      },
    );

    // Create notification channel for Android
    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        'eng_pulse_daily',
        'Daily Briefings',
        description: 'Daily engineering briefing notifications',
        importance: Importance.high,
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
    }
  }

  static Future<void> _getToken() async {
    try {
      _fcmToken = await _messaging!.getToken();
      debugPrint('FCM Token obtained');
      if (_fcmToken != null) {
        await _registerTokenWithBackend(_fcmToken!);
      }
    } catch (e) {
      debugPrint('Failed to get FCM token: $e');
    }
  }

  /// Register FCM token with backend for push notifications
  static Future<void> _registerTokenWithBackend(String token) async {
    try {
      final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'web');

      final response = await http.post(
        Uri.parse(_registerTokenUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'platform': platform,
          'app_version': '1.0.0',
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint('FCM token registered with backend');
      } else {
        debugPrint('Failed to register token: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error registering token with backend: $e');
    }
  }

  static void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('Foreground message received: ${message.messageId}');

    final notification = message.notification;
    final android = message.notification?.android;

    // Show local notification when app is in foreground
    if (notification != null) {
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'eng_pulse_daily',
            'Daily Briefings',
            channelDescription: 'Daily engineering briefing notifications',
            importance: Importance.high,
            priority: Priority.high,
            icon: android?.smallIcon ?? '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: jsonEncode(message.data),
      );
    }
  }

  static void _handleNotificationTap(RemoteMessage message) {
    debugPrint('Notification tapped: ${message.messageId}');
    _handlePayload(jsonEncode(message.data));
  }

  static void _handlePayload(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      debugPrint('Notification payload: $data');

      // Handle navigation based on payload
      // Example: if data contains 'article_url', navigate to that article
      if (data.containsKey('article_url')) {
        // TODO: Navigate to article detail screen
        debugPrint('Should navigate to: ${data['article_url']}');
      }
    } catch (e) {
      debugPrint('Failed to parse notification payload: $e');
    }
  }

  /// Subscribe to a topic
  static Future<void> subscribeToTopic(String topic) async {
    if (!_firebaseAvailable || _messaging == null) return;
    try {
      await _messaging!.subscribeToTopic(topic);
      debugPrint('Subscribed to topic: $topic');
    } catch (e) {
      debugPrint('Failed to subscribe to topic: $e');
    }
  }

  /// Unsubscribe from a topic
  static Future<void> unsubscribeFromTopic(String topic) async {
    if (!_firebaseAvailable || _messaging == null) return;
    try {
      await _messaging!.unsubscribeFromTopic(topic);
      debugPrint('Unsubscribed from topic: $topic');
    } catch (e) {
      debugPrint('Failed to unsubscribe from topic: $e');
    }
  }

  /// Check if notifications are enabled
  static Future<bool> areNotificationsEnabled() async {
    if (!_firebaseAvailable || _messaging == null) return false;
    try {
      final settings = await _messaging!.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized;
    } catch (e) {
      debugPrint('Failed to check notification settings: $e');
      return false;
    }
  }
}
