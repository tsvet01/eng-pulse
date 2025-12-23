import 'package:flutter_test/flutter_test.dart';
import 'package:eng_pulse_mobile/services/cache_service.dart';
import '../helpers/hive_test_helper.dart';
import '../helpers/test_fixtures.dart';

void main() {
  group('CacheService', () {
    setUpAll(() async {
      await HiveTestHelper.setUp();
      await CacheService.initForTesting();
    });

    tearDownAll(() async {
      await CacheService.close();
      await HiveTestHelper.tearDown();
    });

    setUp(() async {
      await CacheService.clearAll();
    });

    group('Summaries', () {
      test('getCachedSummaries returns empty list when no data', () {
        final result = CacheService.getCachedSummaries();
        expect(result, isEmpty);
      });

      test('cacheSummaries stores and retrieves summaries', () async {
        final summaries = [
          TestFixtures.createCachedSummary(date: '2025-01-15', url: 'url1'),
          TestFixtures.createCachedSummary(date: '2025-01-14', url: 'url2'),
        ];

        await CacheService.cacheSummaries(summaries);
        final result = CacheService.getCachedSummaries();

        expect(result.length, 2);
        expect(result[0].date, '2025-01-15'); // Most recent first
        expect(result[1].date, '2025-01-14');
      });

      test('getSummaryByUrl returns correct summary', () async {
        final summary =
            TestFixtures.createCachedSummary(url: 'https://test.com/1');
        await CacheService.cacheSummaries([summary]);

        final result = CacheService.getSummaryByUrl('https://test.com/1');

        expect(result, isNotNull);
        expect(result!.url, 'https://test.com/1');
      });

      test('getSummaryByUrl returns null for non-existent url', () {
        final result = CacheService.getSummaryByUrl('https://nonexistent.com');
        expect(result, isNull);
      });

      test('updateSummary updates existing summary', () async {
        final summary = TestFixtures.createCachedSummary(
          url: 'https://test.com/1',
          title: 'Original Title',
        );
        await CacheService.cacheSummaries([summary]);

        final updated = summary.copyWith(title: 'Updated Title');
        await CacheService.updateSummary(updated);

        final result = CacheService.getSummaryByUrl('https://test.com/1');
        expect(result?.title, 'Updated Title');
      });
    });

    group('Content', () {
      test('getCachedContent returns null when not cached', () {
        final result = CacheService.getCachedContent('https://test.com');
        expect(result, isNull);
      });

      test('cacheContent stores and retrieves content', () async {
        const url = 'https://test.com/content.md';
        const content = '# Test Content\n\nThis is test markdown.';

        await CacheService.cacheContent(url, content);
        final result = CacheService.getCachedContent(url);

        expect(result, content);
      });

      test('hasContent returns correct boolean', () async {
        const url = 'https://test.com/content.md';

        expect(CacheService.hasContent(url), isFalse);

        await CacheService.cacheContent(url, 'content');

        expect(CacheService.hasContent(url), isTrue);
      });

      test('cacheContent also updates summary cachedContent', () async {
        const url = 'https://test.com/1';
        final summary = TestFixtures.createCachedSummary(url: url);
        await CacheService.cacheSummaries([summary]);

        await CacheService.cacheContent(url, 'Cached markdown content');

        final result = CacheService.getSummaryByUrl(url);
        expect(result?.cachedContent, 'Cached markdown content');
      });
    });

    group('Metadata', () {
      test('getLastSummariesUpdate returns null initially', () {
        final result = CacheService.getLastSummariesUpdate();
        expect(result, isNull);
      });

      test('getLastSummariesUpdate returns date after caching summaries',
          () async {
        final before = DateTime.now();
        await CacheService.cacheSummaries([TestFixtures.createCachedSummary()]);
        final after = DateTime.now();

        final result = CacheService.getLastSummariesUpdate();

        expect(result, isNotNull);
        expect(
            result!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
        expect(
            result.isBefore(after.add(const Duration(seconds: 1))), isTrue);
      });

      test('hasCachedData returns correct status', () async {
        expect(CacheService.hasCachedData, isFalse);

        await CacheService.cacheSummaries([TestFixtures.createCachedSummary()]);

        expect(CacheService.hasCachedData, isTrue);
      });
    });

    group('clearAll', () {
      test('clears all cached data', () async {
        await CacheService.cacheSummaries([TestFixtures.createCachedSummary()]);
        await CacheService.cacheContent('url', 'content');

        await CacheService.clearAll();

        expect(CacheService.getCachedSummaries(), isEmpty);
        expect(CacheService.getCachedContent('url'), isNull);
        expect(CacheService.getLastSummariesUpdate(), isNull);
      });
    });
  });
}
