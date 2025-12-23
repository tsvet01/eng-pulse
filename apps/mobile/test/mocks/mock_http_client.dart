import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

class MockHttpClient extends Mock implements http.Client {}

/// Extension to simplify setting up HTTP mock responses
extension MockHttpClientExtension on MockHttpClient {
  void stubGet(
    Uri uri, {
    required int statusCode,
    String body = '',
    Map<String, String>? headers,
  }) {
    when(() => get(uri)).thenAnswer(
      (_) async => http.Response(
        body,
        statusCode,
        headers: headers ?? {},
      ),
    );
  }

  void stubGetThrows(Uri uri, Exception exception) {
    when(() => get(uri)).thenThrow(exception);
  }
}
