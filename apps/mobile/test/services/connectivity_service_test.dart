import 'package:flutter_test/flutter_test.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Tests for ConnectivityService logic.
///
/// Note: The actual ConnectivityService depends on platform channels and can't
/// be easily unit tested. Instead, we test the connectivity result interpretation
/// logic in isolation.
void main() {
  group('Connectivity Result Interpretation', () {
    /// This mirrors the logic in ConnectivityService._updateStatus()
    bool isOnlineFromResults(List<ConnectivityResult> results) {
      return results.isNotEmpty &&
          !results.every((r) => r == ConnectivityResult.none);
    }

    test('isOnline is true when wifi connected', () {
      final results = [ConnectivityResult.wifi];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline is true when mobile connected', () {
      final results = [ConnectivityResult.mobile];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline is true when ethernet connected', () {
      final results = [ConnectivityResult.ethernet];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline is true when vpn connected', () {
      final results = [ConnectivityResult.vpn];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline is true when multiple connections exist', () {
      final results = [ConnectivityResult.wifi, ConnectivityResult.mobile];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline is true when wifi and vpn connected', () {
      final results = [ConnectivityResult.wifi, ConnectivityResult.vpn];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline is false when only none', () {
      final results = [ConnectivityResult.none];
      expect(isOnlineFromResults(results), isFalse);
    });

    test('isOnline is false for empty results', () {
      final results = <ConnectivityResult>[];
      expect(isOnlineFromResults(results), isFalse);
    });

    test('isOnline is true when has connection alongside none', () {
      // This tests an edge case where connectivity_plus might return multiple
      // results including none
      final results = [ConnectivityResult.none, ConnectivityResult.wifi];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline handles other connectivity result', () {
      final results = [ConnectivityResult.other];
      expect(isOnlineFromResults(results), isTrue);
    });

    test('isOnline handles bluetooth connectivity', () {
      final results = [ConnectivityResult.bluetooth];
      expect(isOnlineFromResults(results), isTrue);
    });
  });
}
