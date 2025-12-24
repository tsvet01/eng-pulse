import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Text-to-Speech playback states
enum TtsState { stopped, playing, paused }

/// Service for managing text-to-speech functionality
class TtsService {
  static TtsService? _instance;
  static TtsService get instance => _instance ??= TtsService._();

  TtsService._();

  FlutterTts? _flutterTts;
  bool _isInitialized = false;

  // Current playback state
  TtsState _state = TtsState.stopped;
  TtsState get state => _state;

  // Currently playing article URL (to track which article is being read)
  String? _currentArticleUrl;
  String? get currentArticleUrl => _currentArticleUrl;

  // Current text being spoken
  String? _currentText;
  int _currentPosition = 0;

  // Settings
  double _speechRate = 0.5; // 0.0 to 1.0
  double _pitch = 1.0; // 0.5 to 2.0
  double _volume = 1.0; // 0.0 to 1.0
  String? _selectedVoice;
  String _language = 'en-US';

  // Available voices
  List<Map<String, String>> _voices = [];
  List<Map<String, String>> get voices => _voices;

  // Stream controllers for state changes
  final _stateController = StreamController<TtsState>.broadcast();
  Stream<TtsState> get stateStream => _stateController.stream;

  final _progressController = StreamController<double>.broadcast();
  Stream<double> get progressStream => _progressController.stream;

  // Getters for settings
  double get speechRate => _speechRate;
  double get pitch => _pitch;
  double get volume => _volume;
  String? get selectedVoice => _selectedVoice;
  String get language => _language;

  /// Initialize the TTS engine
  Future<void> init() async {
    if (_isInitialized) return;

    _flutterTts = FlutterTts();

    // Configure TTS
    await _flutterTts!.setLanguage(_language);
    await _flutterTts!.setSpeechRate(_speechRate);
    await _flutterTts!.setPitch(_pitch);
    await _flutterTts!.setVolume(_volume);

    // Platform-specific configuration
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _flutterTts!.setSharedInstance(true);
      await _flutterTts!.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await _flutterTts!.awaitSpeakCompletion(true);
    }

    // Load available voices
    await _loadVoices();

    // Set up handlers
    _flutterTts!.setStartHandler(() {
      _state = TtsState.playing;
      _stateController.add(_state);
    });

    _flutterTts!.setCompletionHandler(() {
      _state = TtsState.stopped;
      _currentArticleUrl = null;
      _currentText = null;
      _currentPosition = 0;
      _stateController.add(_state);
      _progressController.add(0.0);
    });

    _flutterTts!.setCancelHandler(() {
      _state = TtsState.stopped;
      _currentArticleUrl = null;
      _currentText = null;
      _currentPosition = 0;
      _stateController.add(_state);
      _progressController.add(0.0);
    });

    _flutterTts!.setPauseHandler(() {
      _state = TtsState.paused;
      _stateController.add(_state);
    });

    _flutterTts!.setContinueHandler(() {
      _state = TtsState.playing;
      _stateController.add(_state);
    });

    _flutterTts!.setProgressHandler((text, start, end, word) {
      if (_currentText != null && _currentText!.isNotEmpty) {
        _currentPosition = end;
        final progress = end / _currentText!.length;
        _progressController.add(progress.clamp(0.0, 1.0));
      }
    });

    _flutterTts!.setErrorHandler((msg) {
      debugPrint('TTS Error: $msg');
      _state = TtsState.stopped;
      _stateController.add(_state);
    });

    _isInitialized = true;
  }

  Future<void> _loadVoices() async {
    try {
      final voicesResult = await _flutterTts!.getVoices;
      if (voicesResult != null) {
        _voices = List<Map<String, String>>.from(
          (voicesResult as List).map((v) => Map<String, String>.from(v as Map)),
        );
        // Filter for English voices
        _voices = _voices.where((v) {
          final locale = v['locale'] ?? '';
          return locale.startsWith('en');
        }).toList();
      }
    } catch (e) {
      debugPrint('Error loading voices: $e');
    }
  }

  /// Clean markdown text for better TTS readability
  String _cleanTextForSpeech(String text) {
    var cleaned = text;

    // Remove markdown headings
    cleaned = cleaned.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');

    // Remove bold/italic markers
    cleaned = cleaned.replaceAll(RegExp(r'\*{1,2}([^*]+)\*{1,2}'), r'$1');
    cleaned = cleaned.replaceAll(RegExp(r'_{1,2}([^_]+)_{1,2}'), r'$1');

    // Remove inline code
    cleaned = cleaned.replaceAll(RegExp(r'`([^`]+)`'), r'$1');

    // Remove code blocks
    cleaned = cleaned.replaceAll(RegExp(r'```[\s\S]*?```'), '');

    // Remove links but keep the text
    cleaned = cleaned.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');

    // Remove images
    cleaned = cleaned.replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]+\)'), '');

    // Remove HTML tags
    cleaned = cleaned.replaceAll(RegExp(r'<[^>]+>'), '');

    // Remove horizontal rules
    cleaned = cleaned.replaceAll(RegExp(r'^[-*_]{3,}\s*$', multiLine: true), '');

    // Remove list markers
    cleaned = cleaned.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    cleaned = cleaned.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');

    // Remove blockquote markers
    cleaned = cleaned.replaceAll(RegExp(r'^\s*>\s*', multiLine: true), '');

    // Normalize whitespace
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    cleaned = cleaned.replaceAll(RegExp(r' {2,}'), ' ');

    // Add pauses for better pacing (punctuation already provides some)
    cleaned = cleaned.replaceAll(RegExp(r'\n\n'), '. ');

    return cleaned.trim();
  }

  /// Speak the given text
  Future<void> speak(String text, {String? articleUrl}) async {
    if (!_isInitialized) await init();

    // Stop any current playback
    if (_state != TtsState.stopped) {
      await stop();
    }

    _currentText = _cleanTextForSpeech(text);
    _currentArticleUrl = articleUrl;
    _currentPosition = 0;

    _state = TtsState.playing;
    _stateController.add(_state);

    await _flutterTts!.speak(_currentText!);
  }

  /// Pause playback
  Future<void> pause() async {
    if (_state == TtsState.playing) {
      await _flutterTts?.pause();
      _state = TtsState.paused;
      _stateController.add(_state);
    }
  }

  /// Resume playback
  Future<void> resume() async {
    if (_state == TtsState.paused && _currentText != null) {
      // Some platforms don't support resume, so we re-speak from approximate position
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Android doesn't support pause/resume well, so speak remaining text
        final remainingText = _currentText!.substring(_currentPosition);
        await _flutterTts!.speak(remainingText);
      } else {
        await _flutterTts?.speak(_currentText!);
      }
      _state = TtsState.playing;
      _stateController.add(_state);
    }
  }

  /// Stop playback
  Future<void> stop() async {
    await _flutterTts?.stop();
    _state = TtsState.stopped;
    _currentArticleUrl = null;
    _currentText = null;
    _currentPosition = 0;
    _stateController.add(_state);
    _progressController.add(0.0);
  }

  /// Toggle play/pause
  Future<void> togglePlayPause(String text, {String? articleUrl}) async {
    if (_state == TtsState.playing) {
      await pause();
    } else if (_state == TtsState.paused &&
        _currentArticleUrl == articleUrl) {
      await resume();
    } else {
      await speak(text, articleUrl: articleUrl);
    }
  }

  /// Check if currently playing a specific article
  bool isPlayingArticle(String articleUrl) {
    return _state == TtsState.playing && _currentArticleUrl == articleUrl;
  }

  /// Check if paused on a specific article
  bool isPausedOnArticle(String articleUrl) {
    return _state == TtsState.paused && _currentArticleUrl == articleUrl;
  }

  /// Set speech rate (0.0 to 1.0)
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.0, 1.0);
    await _flutterTts?.setSpeechRate(_speechRate);
  }

  /// Set pitch (0.5 to 2.0)
  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
    await _flutterTts?.setPitch(_pitch);
  }

  /// Set volume (0.0 to 1.0)
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _flutterTts?.setVolume(_volume);
  }

  /// Set voice by name
  Future<void> setVoice(String voiceName) async {
    final voice = _voices.firstWhere(
      (v) => v['name'] == voiceName,
      orElse: () => {},
    );
    if (voice.isNotEmpty) {
      await _flutterTts?.setVoice(voice);
      _selectedVoice = voiceName;
    }
  }

  /// Set language
  Future<void> setLanguage(String languageCode) async {
    _language = languageCode;
    await _flutterTts?.setLanguage(_language);
    await _loadVoices();
  }

  /// Get available languages
  Future<List<String>> getLanguages() async {
    if (!_isInitialized) await init();
    try {
      final languages = await _flutterTts!.getLanguages;
      return List<String>.from(languages as List);
    } catch (e) {
      return ['en-US'];
    }
  }

  /// Dispose resources
  void dispose() {
    _flutterTts?.stop();
    _stateController.close();
    _progressController.close();
    _instance = null;
    _isInitialized = false;
  }
}
