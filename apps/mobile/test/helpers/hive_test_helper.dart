import 'dart:io';
import 'package:hive/hive.dart';
import 'package:eng_pulse_mobile/models/cached_summary.dart';
import 'package:eng_pulse_mobile/models/reading_history.dart';

/// Helper class for Hive testing with temporary directories
class HiveTestHelper {
  static Directory? _tempDir;

  /// Initialize Hive with a temporary directory for testing
  static Future<void> setUp() async {
    _tempDir = await Directory.systemTemp.createTemp('hive_test_');
    Hive.init(_tempDir!.path);

    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(CachedSummaryAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ReadingHistoryItemAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(UserPreferencesAdapter());
    }
  }

  /// Clean up after tests
  static Future<void> tearDown() async {
    await Hive.close();
    if (_tempDir != null && await _tempDir!.exists()) {
      await _tempDir!.delete(recursive: true);
    }
    _tempDir = null;
  }
}
