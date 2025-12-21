import 'package:hive_flutter/hive_flutter.dart';
import '../models/cached_summary.dart';

class CacheService {
  static const String _summariesBoxName = 'summaries';
  static const String _contentBoxName = 'content';
  static const String _metadataBoxName = 'metadata';

  static Box<CachedSummary>? _summariesBox;
  static Box<String>? _contentBox;
  static Box<dynamic>? _metadataBox;

  static Future<void> init() async {
    await Hive.initFlutter();

    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(CachedSummaryAdapter());
    }

    try {
      _summariesBox = await Hive.openBox<CachedSummary>(_summariesBoxName);
    } catch (e) {
      // Schema changed - delete old incompatible cache and retry
      await Hive.deleteBoxFromDisk(_summariesBoxName);
      _summariesBox = await Hive.openBox<CachedSummary>(_summariesBoxName);
    }
    _contentBox = await Hive.openBox<String>(_contentBoxName);
    _metadataBox = await Hive.openBox<dynamic>(_metadataBoxName);
  }

  // Summaries
  static List<CachedSummary> getCachedSummaries() {
    if (_summariesBox == null) return [];
    return _summariesBox!.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date)); // Most recent first
  }

  static Future<void> cacheSummaries(List<CachedSummary> summaries) async {
    if (_summariesBox == null) return;

    // Clear old entries and add new ones
    await _summariesBox!.clear();

    for (final summary in summaries) {
      await _summariesBox!.put(summary.url, summary);
    }

    await _metadataBox?.put('lastSummariesUpdate', DateTime.now().toIso8601String());
  }

  static CachedSummary? getSummaryByUrl(String url) {
    return _summariesBox?.get(url);
  }

  static Future<void> updateSummary(CachedSummary summary) async {
    await _summariesBox?.put(summary.url, summary);
  }

  // Content
  static String? getCachedContent(String url) {
    return _contentBox?.get(url);
  }

  static Future<void> cacheContent(String url, String content) async {
    await _contentBox?.put(url, content);

    // Also update the summary's cached content flag
    final summary = _summariesBox?.get(url);
    if (summary != null) {
      final updated = summary.copyWith(
        cachedContent: content,
        lastUpdated: DateTime.now(),
      );
      await _summariesBox?.put(url, updated);
    }
  }

  static bool hasContent(String url) {
    return _contentBox?.containsKey(url) ?? false;
  }

  // Metadata
  static DateTime? getLastSummariesUpdate() {
    final str = _metadataBox?.get('lastSummariesUpdate') as String?;
    if (str == null) return null;
    return DateTime.tryParse(str);
  }

  static bool get hasCachedData {
    return _summariesBox != null && _summariesBox!.isNotEmpty;
  }

  // Cleanup
  static Future<void> clearAll() async {
    await _summariesBox?.clear();
    await _contentBox?.clear();
    await _metadataBox?.clear();
  }

  static Future<void> close() async {
    await _summariesBox?.close();
    await _contentBox?.close();
    await _metadataBox?.close();
  }
}
