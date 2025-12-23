import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:eng_pulse_mobile/services/api_service.dart';
import 'package:eng_pulse_mobile/services/cache_service.dart';
import '../helpers/hive_test_helper.dart';
import '../helpers/test_fixtures.dart';
import '../mocks/mock_http_client.dart';

void main() {
  late MockHttpClient mockClient;
  late ApiService apiService;

  // Mock connectivity checker that always returns online
  Future<bool> alwaysOnline() async => true;

  setUpAll(() async {
    // Register fallback values for mocktail
    registerFallbackValue(Uri());

    await HiveTestHelper.setUp();
    await CacheService.initForTesting();
  });

  tearDownAll(() async {
    await CacheService.close();
    await HiveTestHelper.tearDown();
  });

  setUp(() async {
    mockClient = MockHttpClient();
    apiService = ApiService(
      client: mockClient,
      connectivityChecker: alwaysOnline,
    );
    await CacheService.clearAll();
  });

  group('ApiService', () {
    group('fetchSummaries', () {
      test('returns summaries on successful HTTP response', () async {
        // Arrange
        final manifestJson = TestFixtures.createManifestJson(count: 2);
        mockClient.stubGet(
          Uri.parse(ApiService.manifestUrl),
          statusCode: 200,
          body: manifestJson,
        );

        // Act
        final result = await apiService.fetchSummaries(forceRefresh: true);

        // Assert
        expect(result.length, 2);
        expect(result[0].title, contains('Test Summary'));
      });

      test('caches summaries after successful fetch', () async {
        // Arrange
        mockClient.stubGet(
          Uri.parse(ApiService.manifestUrl),
          statusCode: 200,
          body: TestFixtures.createManifestJson(count: 1),
        );

        // Act
        await apiService.fetchSummaries(forceRefresh: true);

        // Assert
        final cached = CacheService.getCachedSummaries();
        expect(cached.length, 1);
      });

      test('returns cached data on 404 response', () async {
        // Arrange - pre-populate cache
        await CacheService.cacheSummaries([
          TestFixtures.createCachedSummary(title: 'Cached Summary'),
        ]);
        mockClient.stubGet(
          Uri.parse(ApiService.manifestUrl),
          statusCode: 404,
        );

        // Act
        final result = await apiService.fetchSummaries(forceRefresh: true);

        // Assert
        expect(result.length, 1);
        expect(result[0].title, 'Cached Summary');
      });

      test('throws exception on 500 error with no cache', () async {
        // Arrange
        mockClient.stubGet(
          Uri.parse(ApiService.manifestUrl),
          statusCode: 500,
        );

        // Act & Assert
        expect(
          () => apiService.fetchSummaries(forceRefresh: true),
          throwsException,
        );
      });

      test('returns cached data on network error when cache exists', () async {
        // Arrange
        await CacheService.cacheSummaries([
          TestFixtures.createCachedSummary(title: 'Cached'),
        ]);
        mockClient.stubGetThrows(
          Uri.parse(ApiService.manifestUrl),
          Exception('Network error'),
        );

        // Act
        final result = await apiService.fetchSummaries(forceRefresh: true);

        // Assert
        expect(result.length, 1);
        expect(result[0].title, 'Cached');
      });

      test('uses cached data when cache is fresh and not forcing refresh',
          () async {
        // Arrange - cache with recent timestamp
        await CacheService.cacheSummaries([
          TestFixtures.createCachedSummary(title: 'Fresh Cache'),
        ]);

        // Act - should not make HTTP request because cache is fresh
        final result = await apiService.fetchSummaries(forceRefresh: false);

        // Assert
        expect(result[0].title, 'Fresh Cache');
        verifyNever(() => mockClient.get(any()));
      });

      test('parses JSON with all fields correctly', () async {
        // Arrange
        final json = '''[{
          "date": "2025-01-15",
          "url": "https://storage.example.com/test.md",
          "title": "Full Test Summary",
          "summary_snippet": "Complete snippet",
          "original_url": "https://original.com/article",
          "model": "gemini",
          "selected_by": "claude"
        }]''';
        mockClient.stubGet(
          Uri.parse(ApiService.manifestUrl),
          statusCode: 200,
          body: json,
        );

        // Act
        final result = await apiService.fetchSummaries(forceRefresh: true);

        // Assert
        expect(result.length, 1);
        expect(result[0].date, '2025-01-15');
        expect(result[0].title, 'Full Test Summary');
        expect(result[0].originalUrl, 'https://original.com/article');
        expect(result[0].model, 'gemini');
        expect(result[0].selectedBy, 'claude');
      });
    });

    group('fetchMarkdown', () {
      const testUrl = 'https://storage.example.com/test.md';
      const testContent = '# Test Markdown\n\nContent here.';

      test('fetches and returns markdown content', () async {
        // Arrange
        mockClient.stubGet(
          Uri.parse(testUrl),
          statusCode: 200,
          body: testContent,
        );

        // Act
        final result = await apiService.fetchMarkdown(testUrl);

        // Assert
        expect(result, testContent);
      });

      test('caches content after successful fetch', () async {
        // Arrange
        mockClient.stubGet(
          Uri.parse(testUrl),
          statusCode: 200,
          body: testContent,
        );

        // Act
        await apiService.fetchMarkdown(testUrl);

        // Assert
        expect(CacheService.getCachedContent(testUrl), testContent);
      });

      test('returns cached content on network error when available', () async {
        // Arrange
        await CacheService.cacheContent(testUrl, 'Cached content');
        mockClient.stubGetThrows(
          Uri.parse(testUrl),
          Exception('Network error'),
        );

        // Act
        final result = await apiService.fetchMarkdown(testUrl);

        // Assert
        expect(result, 'Cached content');
      });

      test('throws when no cache and network fails', () async {
        // Arrange
        mockClient.stubGetThrows(
          Uri.parse(testUrl),
          Exception('Network error'),
        );

        // Act & Assert
        expect(
          () => apiService.fetchMarkdown(testUrl),
          throwsException,
        );
      });

      test('throws on non-200 status without cache', () async {
        // Arrange
        mockClient.stubGet(
          Uri.parse(testUrl),
          statusCode: 404,
        );

        // Act & Assert
        expect(
          () => apiService.fetchMarkdown(testUrl),
          throwsException,
        );
      });
    });
  });
}
