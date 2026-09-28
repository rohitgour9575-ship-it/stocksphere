import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Ensure Firebase is initialized for background isolate if needed
  await Firebase.initializeApp();
  debugPrint("Handling a background message: ${message.messageId}");
  debugPrint("Message data: ${message.data}");

  // If it's a data-only message (or contains data fallback), show it using local notifications
  if (message.notification == null && message.data.isNotEmpty) {
    final title = message.data['title'] ?? message.data['message'] ?? message.data['notification_title'];
    final body = message.data['body'] ?? message.data['message_body'] ?? message.data['notification_body'];

    if (title != null && body != null) {
      final FlutterLocalNotificationsPlugin localNotificationsPlugin =
          FlutterLocalNotificationsPlugin();

      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'high_importance_channel', // id
        'High Importance Notifications', // name
        description: 'This channel is used for important notifications.', // description
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

      // Create channel (needed for Android 8.0+)
      await localNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      await localNotificationsPlugin.initialize(
        settings: const InitializationSettings(android: initializationSettingsAndroid),
      );

      await localNotificationsPlugin.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            icon: '@mipmap/ic_launcher',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
          ),
        ),
        payload: message.data.toString(),
      );
    }
  }
}

class PushNotificationHelper {
  static final PushNotificationHelper _instance = PushNotificationHelper._internal();
  factory PushNotificationHelper() => _instance;
  PushNotificationHelper._internal();

  late final FirebaseMessaging _firebaseMessaging;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  /// Called when FCM token is first obtained or refreshed.
  static void Function(String token)? onTokenChanged;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;

    try {
      // 1. Initialize Firebase Core
      // Note: This will succeed if google-services.json (Android) or GoogleService-Info.plist (iOS) are present.
      await Firebase.initializeApp();
      _firebaseMessaging = FirebaseMessaging.instance;
      debugPrint("Firebase successfully initialized in PushNotificationHelper");
    } catch (e) {
      debugPrint("========================================================================");
      debugPrint("WARNING: Firebase initialization failed.");
      debugPrint("Please make sure you have added google-services.json / GoogleService-Info.plist.");
      debugPrint("Error: $e");
      debugPrint("========================================================================");
      return;
    }

    try {
      // 2. Register background handler
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // 3. Request permissions (crucial for iOS & Android 13+)
      NotificationSettings settings = await _firebaseMessaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      debugPrint('User notification permission status: ${settings.authorizationStatus}');

      // 4. Setup Android Foreground Notification Channel
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'high_importance_channel', // id
        'High Importance Notifications', // name
        description: 'This channel is used for important notifications.', // description
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

      await _localNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      // 5. Initialize Local Notifications
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      
      const DarwinInitializationSettings initializationSettingsDarwin =
          DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );

      const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsDarwin,
      );

      await _localNotificationsPlugin.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint("Notification clicked: ${response.payload}");
        },
      );

      // 6. Listen to foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        debugPrint('Message data: ${message.data}');

        String? title;
        String? body;

        if (message.notification != null) {
          title = message.notification?.title;
          body = message.notification?.body;
        } else if (message.data.isNotEmpty) {
          title = message.data['title'] ?? message.data['message'] ?? message.data['notification_title'];
          body = message.data['body'] ?? message.data['message_body'] ?? message.data['notification_body'];
        }

        if (title != null && body != null && !kIsWeb) {
          RemoteNotification? notification = message.notification;
          AndroidNotification? android = message.notification?.android;

          _localNotificationsPlugin.show(
            id: notification?.hashCode ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
            title: title,
            body: body,
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                channel.id,
                channel.name,
                channelDescription: channel.description,
                icon: android?.smallIcon ?? '@mipmap/ic_launcher',
                importance: Importance.max,
                priority: Priority.high,
                playSound: true,
              ),
              iOS: const DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            payload: message.data.toString(),
          );
        }
      });

      // 7. Get and print the FCM token
      _fcmToken = await _firebaseMessaging.getToken();
      debugPrint("==========================================================");
      debugPrint("FCM Token: $_fcmToken");
      debugPrint("==========================================================");
      if (_fcmToken != null) onTokenChanged?.call(_fcmToken!);

      // Monitor token refreshes
      _firebaseMessaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        debugPrint("FCM Token refreshed: $newToken");
        onTokenChanged?.call(newToken);
      });

      // 8. Handle app opened from notification when in background
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('Notification clicked and app opened: ${message.data}');
      });

      // 9. Handle app opened from notification when terminated
      RemoteMessage? initialMessage = await _firebaseMessaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('App opened from terminated state via notification: ${initialMessage.data}');
      }

      _initialized = true;
    } catch (e) {
      debugPrint("Error initializing Firebase Messaging: $e");
    }
  }
}
