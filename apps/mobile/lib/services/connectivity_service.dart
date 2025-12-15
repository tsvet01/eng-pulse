import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  static final Connectivity _connectivity = Connectivity();
  static StreamSubscription<List<ConnectivityResult>>? _subscription;

  static bool _isOnline = true;
  static final _onlineController = StreamController<bool>.broadcast();

  static bool get isOnline => _isOnline;
  static Stream<bool> get onConnectivityChanged => _onlineController.stream;

  static Future<void> init() async {
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);

    _subscription = _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  static void _updateStatus(List<ConnectivityResult> results) {
    final wasOnline = _isOnline;
    _isOnline = results.isNotEmpty &&
        !results.every((r) => r == ConnectivityResult.none);

    if (wasOnline != _isOnline) {
      _onlineController.add(_isOnline);
    }
  }

  static Future<bool> checkConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);
    return _isOnline;
  }

  static void dispose() {
    _subscription?.cancel();
    _onlineController.close();
  }
}
