import 'package:hive_flutter/hive_flutter.dart';
import '../models/reading_history.dart';
import '../models/cached_summary.dart';

class UserService {
  static const String _historyBoxName = 'reading_history';
  static const String _preferencesBoxName = 'user_preferences';

  static Box<ReadingHistoryItem>? _historyBox;
  static Box<UserPreferences>? _preferencesBox;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ReadingHistoryItemAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(UserPreferencesAdapter());
    }

    _historyBox = await Hive.openBox<ReadingHistoryItem>(_historyBoxName);
    _preferencesBox = await Hive.openBox<UserPreferences>(_preferencesBoxName);
  }

  // Reading History
  static List<ReadingHistoryItem> getReadingHistory() {
    if (_historyBox == null) return [];
    return _historyBox!.values.toList()
      ..sort((a, b) => b.readAt.compareTo(a.readAt)); // Most recent first
  }

  static Future<void> addToHistory(CachedSummary summary) async {
    if (_historyBox == null) return;

    // Check if already in history
    final existing = _historyBox!.values.where((item) => item.url == summary.url).firstOrNull;
    if (existing != null) {
      // Update read time
      existing.delete();
    }

    final item = ReadingHistoryItem(
      url: summary.url,
      title: summary.title,
      date: summary.date,
      readAt: DateTime.now(),
    );

    await _historyBox!.put(summary.url, item);
  }

  static Future<void> setFeedback(String url, int feedback) async {
    final item = _historyBox?.get(url);
    if (item != null) {
      item.feedback = feedback;
      await item.save();
    }
  }

  static int? getFeedback(String url) {
    return _historyBox?.get(url)?.feedback;
  }

  static bool hasRead(String url) {
    return _historyBox?.containsKey(url) ?? false;
  }

  static Future<void> clearHistory() async {
    await _historyBox?.clear();
  }

  // User Preferences
  static UserPreferences getPreferences() {
    if (_preferencesBox == null || _preferencesBox!.isEmpty) {
      return UserPreferences();
    }
    return _preferencesBox!.get('prefs') ?? UserPreferences();
  }

  static Future<void> savePreferences(UserPreferences prefs) async {
    await _preferencesBox?.put('prefs', prefs);
  }

  static Future<void> setNotificationsEnabled(bool enabled) async {
    final prefs = getPreferences();
    prefs.notificationsEnabled = enabled;
    await savePreferences(prefs);
  }

  static Future<void> setDailyBriefingEnabled(bool enabled) async {
    final prefs = getPreferences();
    prefs.dailyBriefingEnabled = enabled;
    await savePreferences(prefs);
  }
}
