import 'package:flutter_test/flutter_test.dart';
import 'package:eng_pulse_mobile/models/summary.dart';

void main() {
  group('Summary', () {
    group('fromJson', () {
      test('parses all fields correctly', () {
        final json = {
          'date': '2025-01-15',
          'url': 'https://storage.example.com/test.md',
          'title': 'Test Title',
          'summary_snippet': 'Test snippet',
          'original_url': 'https://example.com/article',
          'model': 'gemini',
          'selected_by': 'claude',
        };

        final summary = Summary.fromJson(json);

        expect(summary.date, '2025-01-15');
        expect(summary.url, 'https://storage.example.com/test.md');
        expect(summary.title, 'Test Title');
        expect(summary.summarySnippet, 'Test snippet');
        expect(summary.originalUrl, 'https://example.com/article');
        expect(summary.model, 'gemini');
        expect(summary.selectedBy, 'claude');
      });

      test('handles null optional fields', () {
        final json = {
          'date': '2025-01-15',
          'url': 'https://storage.example.com/test.md',
          'title': 'Test Title',
          'summary_snippet': 'Test snippet',
        };

        final summary = Summary.fromJson(json);

        expect(summary.originalUrl, isNull);
        expect(summary.model, isNull);
        expect(summary.selectedBy, isNull);
      });
    });
  });

  group('LlmModel', () {
    group('fromId', () {
      test('returns correct model for exact ID match', () {
        expect(LlmModel.fromId('gemini-3-pro-preview'), LlmModel.gemini);
        expect(LlmModel.fromId('gpt-5.2-2025-12-11'), LlmModel.openai);
        expect(LlmModel.fromId('claude-opus-4-5'), LlmModel.claude);
      });

      test('returns correct model for vendor name', () {
        expect(LlmModel.fromId('gemini'), LlmModel.gemini);
        expect(LlmModel.fromId('openai'), LlmModel.openai);
        expect(LlmModel.fromId('claude'), LlmModel.claude);
      });

      test('returns gemini as default for null', () {
        expect(LlmModel.fromId(null), LlmModel.gemini);
      });

      test('returns gemini as default for unknown id', () {
        expect(LlmModel.fromId('unknown'), LlmModel.gemini);
        expect(LlmModel.fromId('some-random-model'), LlmModel.gemini);
      });
    });

    group('matchesId', () {
      test('returns true for exact ID match', () {
        expect(LlmModel.gemini.matchesId('gemini-3-pro-preview'), isTrue);
        expect(LlmModel.openai.matchesId('gpt-5.2-2025-12-11'), isTrue);
        expect(LlmModel.claude.matchesId('claude-opus-4-5'), isTrue);
      });

      test('returns true for vendor name match', () {
        expect(LlmModel.gemini.matchesId('gemini'), isTrue);
        expect(LlmModel.openai.matchesId('openai'), isTrue);
        expect(LlmModel.claude.matchesId('claude'), isTrue);
      });

      test('returns false for wrong model', () {
        expect(LlmModel.gemini.matchesId('claude'), isFalse);
        expect(LlmModel.openai.matchesId('gemini'), isFalse);
        expect(LlmModel.claude.matchesId('openai'), isFalse);
      });

      test('returns false for null', () {
        expect(LlmModel.gemini.matchesId(null), isFalse);
        expect(LlmModel.openai.matchesId(null), isFalse);
        expect(LlmModel.claude.matchesId(null), isFalse);
      });
    });

    group('vendor', () {
      test('returns correct vendor name', () {
        expect(LlmModel.gemini.vendor, 'gemini');
        expect(LlmModel.openai.vendor, 'openai');
        expect(LlmModel.claude.vendor, 'claude');
      });
    });

    group('displayName', () {
      test('returns correct display name', () {
        expect(LlmModel.gemini.displayName, 'Gemini');
        expect(LlmModel.openai.displayName, 'OpenAI');
        expect(LlmModel.claude.displayName, 'Claude');
      });
    });
  });
}
