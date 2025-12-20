import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/summary.dart';
import '../models/cached_summary.dart';
import 'cache_service.dart';
import 'connectivity_service.dart';

class ApiService {
  /// GCS bucket name - can be overridden for testing or different environments
  static const String defaultBucket = 'tsvet01-agent-brain';

  /// Constructs the manifest URL from bucket name
  static String get manifestUrl =>
      'https://storage.googleapis.com/$defaultBucket/manifest.json';

  Future<List<CachedSummary>> fetchSummaries({bool forceRefresh = false}) async {
    // Check connectivity
    final isOnline = await ConnectivityService.checkConnectivity();

    if (!isOnline || (!forceRefresh && _shouldUseCachedData())) {
      // Return cached data if offline or cache is fresh
      final cached = CacheService.getCachedSummaries();
      if (cached.isNotEmpty) {
        return cached;
      }
    }

    if (!isOnline) {
      // Offline and no cache - return empty
      return [];
    }

    try {
      final response = await http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        // Decode as UTF-8 to properly handle non-ASCII characters (e.g., Cyrillic)
        final List<dynamic> jsonList = json.decode(utf8.decode(response.bodyBytes));
        final summaries = jsonList.map((json) {
          final summary = Summary.fromJson(json);
          return CachedSummary(
            date: summary.date,
            url: summary.url,
            title: summary.title,
            summarySnippet: summary.summarySnippet,
            cachedContent: CacheService.getCachedContent(summary.url),
            lastUpdated: DateTime.now(),
            originalUrl: summary.originalUrl,
          );
        }).toList();

        // Cache the summaries
        await CacheService.cacheSummaries(summaries);

        return summaries;
      } else if (response.statusCode == 404) {
        return CacheService.getCachedSummaries();
      } else {
        throw Exception('Failed to load summaries: ${response.statusCode}');
      }
    } catch (e) {
      // On error, return cached data if available
      final cached = CacheService.getCachedSummaries();
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  Future<String> fetchMarkdown(String url) async {
    // Check if we have cached content
    final cachedContent = CacheService.getCachedContent(url);

    final isOnline = await ConnectivityService.checkConnectivity();

    if (!isOnline) {
      if (cachedContent != null) {
        return cachedContent;
      }
      throw Exception('No internet connection and content not cached');
    }

    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final content = utf8.decode(response.bodyBytes);

        // Cache the content
        await CacheService.cacheContent(url, content);

        return content;
      } else {
        throw Exception('Failed to load markdown content');
      }
    } catch (e) {
      // On error, return cached if available
      if (cachedContent != null) {
        return cachedContent;
      }
      rethrow;
    }
  }

  bool _shouldUseCachedData() {
    final lastUpdate = CacheService.getLastSummariesUpdate();
    if (lastUpdate == null) return false;

    // Consider cache fresh if updated within the last hour
    final freshness = DateTime.now().difference(lastUpdate);
    return freshness.inHours < 1;
  }

  /// Pre-cache content for offline reading
  Future<void> preCacheContent(List<CachedSummary> summaries) async {
    final isOnline = await ConnectivityService.checkConnectivity();
    if (!isOnline) return;

    for (final summary in summaries) {
      if (!CacheService.hasContent(summary.url)) {
        try {
          await fetchMarkdown(summary.url);
        } catch (_) {
          // Ignore errors during pre-caching
        }
      }
    }
  }
}
