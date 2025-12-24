import 'package:flutter_test/flutter_test.dart';
import 'package:eng_pulse_mobile/services/user_service.dart';
import 'package:eng_pulse_mobile/models/reading_history.dart';
import '../helpers/hive_test_helper.dart';
import '../helpers/test_fixtures.dart';

void main() {
  group('UserService', () {
    setUpAll(() async {
      await HiveTestHelper.setUp();
      await UserService.initForTesting();
    });

    tearDownAll(() async {
      await UserService.close();
      await HiveTestHelper.tearDown();
    });

    setUp(() async {
      await UserService.clearHistory();
      // Reset preferences to defaults
      await UserService.savePreferences(UserPreferences());
    });

    group('Reading History', () {
      test('getReadingHistory returns empty list initially', () {
        final result = UserService.getReadingHistory();
        expect(result, isEmpty);
      });

      test('addToHistory adds item to history', () async {
        final summary = TestFixtures.createCachedSummary(
          url: 'https://test.com/1',
          title: 'Test Article',
        );

        await UserService.addToHistory(summary);
        final history = UserService.getReadingHistory();

        expect(history.length, 1);
        expect(history[0].title, 'Test Article');
        expect(history[0].url, 'https://test.com/1');
      });

      test('addToHistory updates existing entry timestamp', () async {
        final summary =
            TestFixtures.createCachedSummary(url: 'https://test.com/1');

        await UserService.addToHistory(summary);
        final firstReadAt = UserService.getReadingHistory()[0].readAt;

        await Future.delayed(const Duration(milliseconds: 10));
        await UserService.addToHistory(summary);
        final secondReadAt = UserService.getReadingHistory()[0].readAt;

        expect(secondReadAt.isAfter(firstReadAt), isTrue);
        expect(
            UserService.getReadingHistory().length, 1); // Still only one entry
      });

      test('hasRead returns correct boolean', () async {
        const url = 'https://test.com/1';

        expect(UserService.hasRead(url), isFalse);

        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: url));

        expect(UserService.hasRead(url), isTrue);
      });

      test('getReadingHistory returns items sorted by readAt descending',
          () async {
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: 'url1', title: 'First'));
        await Future.delayed(const Duration(milliseconds: 10));
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: 'url2', title: 'Second'));

        final history = UserService.getReadingHistory();

        expect(history[0].title, 'Second'); // Most recent first
        expect(history[1].title, 'First');
      });
    });

    group('Feedback', () {
      test('setFeedback stores feedback for read article', () async {
        const url = 'https://test.com/1';
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: url));

        await UserService.setFeedback(url, 1); // Thumbs up

        expect(UserService.getFeedback(url), 1);
      });

      test('setFeedback can set negative feedback', () async {
        const url = 'https://test.com/1';
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: url));

        await UserService.setFeedback(url, -1); // Thumbs down

        expect(UserService.getFeedback(url), -1);
      });

      test('clearFeedback removes feedback', () async {
        const url = 'https://test.com/1';
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: url));
        await UserService.setFeedback(url, 1);

        await UserService.clearFeedback(url);

        expect(UserService.getFeedback(url), isNull);
      });

      test('getFeedback returns null for unread article', () {
        expect(UserService.getFeedback('https://unread.com'), isNull);
      });

      test('setFeedback with null clears feedback', () async {
        const url = 'https://test.com/1';
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: url));
        await UserService.setFeedback(url, 1);

        await UserService.setFeedback(url, null);

        expect(UserService.getFeedback(url), isNull);
      });
    });

    group('User Preferences', () {
      test('getPreferences returns defaults initially', () {
        final prefs = UserService.getPreferences();

        expect(prefs.notificationsEnabled, isTrue);
        expect(prefs.dailyBriefingEnabled, isTrue);
        expect(prefs.selectedModel, 'gemini');
      });

      test('setNotificationsEnabled updates preference', () async {
        await UserService.setNotificationsEnabled(false);

        expect(UserService.getPreferences().notificationsEnabled, isFalse);
      });

      test('setDailyBriefingEnabled updates preference', () async {
        await UserService.setDailyBriefingEnabled(false);

        expect(UserService.getPreferences().dailyBriefingEnabled, isFalse);
      });

      test('setSelectedModel updates preference', () async {
        await UserService.setSelectedModel('claude');

        expect(UserService.getSelectedModel(), 'claude');
      });

      test('savePreferences persists all preferences', () async {
        final prefs = UserPreferences(
          notificationsEnabled: false,
          dailyBriefingEnabled: false,
          selectedModel: 'openai',
        );

        await UserService.savePreferences(prefs);
        final loaded = UserService.getPreferences();

        expect(loaded.notificationsEnabled, isFalse);
        expect(loaded.dailyBriefingEnabled, isFalse);
        expect(loaded.selectedModel, 'openai');
      });
    });

    group('clearHistory', () {
      test('clears all reading history', () async {
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: 'url1'));
        await UserService.addToHistory(
            TestFixtures.createCachedSummary(url: 'url2'));

        await UserService.clearHistory();

        expect(UserService.getReadingHistory(), isEmpty);
      });
    });

    group('TTS Settings', () {
      test('getTtsSpeechRate returns default value initially', () {
        final rate = UserService.getTtsSpeechRate();
        expect(rate, 0.5);
      });

      test('setTtsSpeechRate updates preference', () async {
        await UserService.setTtsSpeechRate(0.75);

        expect(UserService.getTtsSpeechRate(), 0.75);
      });

      test('setTtsSpeechRate clamps value to valid range', () async {
        await UserService.setTtsSpeechRate(1.5); // Above max
        expect(UserService.getTtsSpeechRate(), 1.0);

        await UserService.setTtsSpeechRate(-0.5); // Below min
        expect(UserService.getTtsSpeechRate(), 0.0);
      });

      test('getTtsPitch returns default value initially', () {
        final pitch = UserService.getTtsPitch();
        expect(pitch, 1.0);
      });

      test('setTtsPitch updates preference', () async {
        await UserService.setTtsPitch(1.5);

        expect(UserService.getTtsPitch(), 1.5);
      });

      test('setTtsPitch clamps value to valid range', () async {
        await UserService.setTtsPitch(3.0); // Above max
        expect(UserService.getTtsPitch(), 2.0);

        await UserService.setTtsPitch(0.1); // Below min
        expect(UserService.getTtsPitch(), 0.5);
      });

      test('getTtsVoice returns null initially', () {
        final voice = UserService.getTtsVoice();
        expect(voice, isNull);
      });

      test('setTtsVoice updates preference', () async {
        await UserService.setTtsVoice('en-US-Wavenet-A');

        expect(UserService.getTtsVoice(), 'en-US-Wavenet-A');
      });

      test('setTtsVoice can be set to null', () async {
        await UserService.setTtsVoice('some-voice');
        await UserService.setTtsVoice(null);

        expect(UserService.getTtsVoice(), isNull);
      });
    });
  });
}
