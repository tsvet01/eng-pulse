import 'package:eng_pulse_mobile/models/cached_summary.dart';
import 'package:eng_pulse_mobile/models/summary.dart';

/// Factory methods for creating test fixtures
class TestFixtures {
  static Summary createSummary({
    String date = '2025-01-15',
    String url = 'https://storage.example.com/test.md',
    String title = 'Test Summary',
    String summarySnippet = 'Test snippet content',
    String? originalUrl,
    String? model = 'gemini',
    String? selectedBy,
  }) {
    return Summary(
      date: date,
      url: url,
      title: title,
      summarySnippet: summarySnippet,
      originalUrl: originalUrl,
      model: model,
      selectedBy: selectedBy,
    );
  }

  static CachedSummary createCachedSummary({
    String date = '2025-01-15',
    String url = 'https://storage.example.com/test.md',
    String title = 'Test Cached Summary',
    String summarySnippet = 'Test snippet content',
    String? cachedContent,
    DateTime? lastUpdated,
    String? originalUrl,
    String? model = 'gemini',
    String? selectedBy,
  }) {
    return CachedSummary(
      date: date,
      url: url,
      title: title,
      summarySnippet: summarySnippet,
      cachedContent: cachedContent,
      lastUpdated: lastUpdated ?? DateTime.now(),
      originalUrl: originalUrl,
      model: model,
      selectedBy: selectedBy,
    );
  }

  static String createManifestJson({int count = 3}) {
    final items = List.generate(
        count,
        (i) => '''
    {
      "date": "2025-01-${(15 - i).toString().padLeft(2, '0')}",
      "url": "https://storage.example.com/summary_$i.md",
      "title": "Test Summary $i",
      "summary_snippet": "Snippet for summary $i",
      "original_url": "https://example.com/article_$i",
      "model": "gemini",
      "selected_by": "gemini"
    }
    ''');
    return '[${items.join(',')}]';
  }
}
