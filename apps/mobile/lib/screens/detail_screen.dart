import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/cached_summary.dart';
import '../models/summary.dart';
import '../services/api_service.dart';
import '../services/cache_service.dart';
import '../services/connectivity_service.dart';
import '../services/tts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/feedback_widget.dart';
import '../services/user_service.dart';

class DetailScreen extends StatefulWidget {
  final CachedSummary summary;
  final List<CachedSummary>? allSummaries;
  final int? currentIndex;

  const DetailScreen({
    super.key,
    required this.summary,
    this.allSummaries,
    this.currentIndex,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final ApiService _apiService = ApiService();
  final TtsService _ttsService = TtsService.instance;
  late Future<String> _contentFuture;
  late CachedSummary _currentSummary;
  late int _currentIndex;
  bool _isCached = false;

  // TTS state
  TtsState _ttsState = TtsState.stopped;
  double _ttsProgress = 0.0;
  StreamSubscription<TtsState>? _ttsStateSubscription;
  StreamSubscription<double>? _ttsProgressSubscription;
  String? _loadedContent;

  bool get _hasPrevious =>
      widget.allSummaries != null && _currentIndex > 0;
  bool get _hasNext =>
      widget.allSummaries != null &&
      _currentIndex < (widget.allSummaries!.length - 1);

  @override
  void initState() {
    super.initState();
    _currentSummary = widget.summary;
    _currentIndex = widget.currentIndex ?? 0;
    _loadCurrentArticle();
    _initTts();
  }

  Future<void> _initTts() async {
    await _ttsService.init();

    // Load user's TTS preferences
    final speechRate = UserService.getTtsSpeechRate();
    final pitch = UserService.getTtsPitch();

    await _ttsService.setSpeechRate(speechRate);
    await _ttsService.setPitch(pitch);

    // Check if already playing this article
    if (_ttsService.currentArticleUrl == _currentSummary.url) {
      _ttsState = _ttsService.state;
    }

    _ttsStateSubscription = _ttsService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _ttsState = state;
        });
      }
    });

    _ttsProgressSubscription = _ttsService.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _ttsProgress = progress;
        });
      }
    });
  }

  @override
  void dispose() {
    _ttsStateSubscription?.cancel();
    _ttsProgressSubscription?.cancel();
    super.dispose();
  }

  void _loadCurrentArticle() {
    _isCached = CacheService.hasContent(_currentSummary.url);
    _contentFuture = _apiService.fetchMarkdown(_currentSummary.url);
    UserService.addToHistory(_currentSummary);
  }

  void _navigateTo(int index) {
    if (widget.allSummaries == null) return;
    // Stop TTS when navigating to another article
    if (_ttsState != TtsState.stopped) {
      _ttsService.stop();
    }
    setState(() {
      _currentIndex = index;
      _currentSummary = widget.allSummaries![index];
      _loadedContent = null;
      _ttsProgress = 0.0;
      _loadCurrentArticle();
    });
  }

  Future<void> _toggleTts() async {
    if (_loadedContent == null) return;

    final isCurrentArticle = _ttsService.currentArticleUrl == _currentSummary.url;

    if (_ttsState == TtsState.playing && isCurrentArticle) {
      await _ttsService.pause();
    } else if (_ttsState == TtsState.paused && isCurrentArticle) {
      await _ttsService.resume();
    } else {
      await _ttsService.speak(_loadedContent!, articleUrl: _currentSummary.url);
    }
  }

  Future<void> _stopTts() async {
    await _ttsService.stop();
  }

  void _retry() {
    setState(() {
      _contentFuture = _apiService.fetchMarkdown(_currentSummary.url);
    });
  }

  Future<void> _openOriginalArticle() async {
    final originalUrl = _currentSummary.originalUrl;
    if (originalUrl == null || originalUrl.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Original article link not available'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    final uri = Uri.parse(originalUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _shareArticle() async {
    await Share.share(
      '${_currentSummary.title}\n\n${_currentSummary.summarySnippet}\n\nRead on Eng Pulse',
      subject: _currentSummary.title,
    );
  }

  String _extractSourceName(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host.replaceFirst('www.', '');
      // Extract domain name without TLD for cleaner display
      final parts = host.split('.');
      if (parts.length >= 2) {
        return parts[parts.length - 2].replaceAll('-', ' ').split(' ').map((w) =>
            w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w).join(' ');
      }
      return host;
    } catch (e) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isOnline = ConnectivityService.isOnline;

    final isCurrentArticlePlaying = _ttsService.currentArticleUrl == _currentSummary.url;
    final showPlayerBar = _ttsState != TtsState.stopped && isCurrentArticlePlaying;

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // App Bar
              SliverAppBar(
            floating: true,
            snap: true,
            backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.darkSurface : AppTheme.lightSurface),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
                  ),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                ),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              // Listen button
              if (_loadedContent != null)
                IconButton(
                  icon: Icon(
                    _ttsState == TtsState.playing
                        ? Icons.pause_rounded
                        : (_ttsState == TtsState.paused
                            ? Icons.play_arrow_rounded
                            : Icons.headphones_rounded),
                    color: _ttsState != TtsState.stopped
                        ? (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple)
                        : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                  ),
                  onPressed: _toggleTts,
                  tooltip: _ttsState == TtsState.playing ? 'Pause' : 'Listen',
                ),
              IconButton(
                icon: Icon(
                  Icons.open_in_new_rounded,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
                onPressed: _openOriginalArticle,
                tooltip: 'Open original',
              ),
              IconButton(
                icon: Icon(
                  Icons.share_rounded,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
                onPressed: _shareArticle,
                tooltip: 'Share',
              ),
              const SizedBox(width: 8),
            ],
          ),

          // Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Date chip, model badge, source, and offline indicator
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple)
                              .withAlpha(25),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _currentSummary.date,
                          style: TextStyle(
                            color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Model badge
                      if (_currentSummary.model != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: (isDark ? Colors.teal.shade300 : Colors.teal.shade600)
                                .withAlpha(25),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            LlmModel.fromId(_currentSummary.model).displayName,
                            style: TextStyle(
                              color: isDark ? Colors.teal.shade300 : Colors.teal.shade600,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      if (_currentSummary.originalUrl != null) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _openOriginalArticle,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: (isDark ? Colors.blue.shade300 : Colors.blue.shade600)
                                  .withAlpha(25),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: (isDark ? Colors.blue.shade300 : Colors.blue.shade600)
                                    .withAlpha(50),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.open_in_new_rounded,
                                  size: 12,
                                  color: isDark ? Colors.blue.shade300 : Colors.blue.shade600,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _extractSourceName(_currentSummary.originalUrl!),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isDark ? Colors.blue.shade300 : Colors.blue.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (!isOnline && _isCached) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade700.withAlpha(30),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.cloud_off_rounded,
                                size: 14,
                                color: Colors.orange.shade700,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Offline',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Title with Hero transition
                  Hero(
                    tag: 'title-${_currentSummary.url}',
                    flightShuttleBuilder: (flightContext, animation, flightDirection,
                        fromHeroContext, toHeroContext) {
                      return Material(
                        color: Colors.transparent,
                        child: toHeroContext.widget,
                      );
                    },
                    child: Text(
                      _currentSummary.title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Divider
          SliverToBoxAdapter(
            child: Divider(
              color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
              height: 1,
            ),
          ),

          // Content
          SliverFillRemaining(
            child: FutureBuilder<String>(
              future: _contentFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  // Check if content is cached
                  final cached = CacheService.getCachedContent(_currentSummary.url);
                  if (cached != null) {
                    return _buildMarkdownContent(context, cached, isDark);
                  }

                  if (!isOnline) {
                    return const ErrorState(
                      message: 'You\'re offline and this article hasn\'t been cached yet.',
                    );
                  }
                  return ErrorState(
                    message: 'Failed to load content',
                    onRetry: _retry,
                  );
                }

                final content = snapshot.data ?? '';

                // Save content for TTS and update cached state
                if (_loadedContent != content) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        _loadedContent = content;
                        if (!_isCached) {
                          _isCached = true;
                        }
                      });
                    }
                  });
                }

                return _buildMarkdownContent(context, content, isDark);
              },
            ),
          ),
        ],
      ),
          // TTS Player Bar
          if (showPlayerBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildTtsPlayerBar(context, isDark),
            ),
        ],
      ),
    );
  }

  Widget _buildTtsPlayerBar(BuildContext context, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(25),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar
          LinearProgressIndicator(
            value: _ttsProgress,
            backgroundColor: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
            valueColor: AlwaysStoppedAnimation<Color>(
              isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
            ),
            minHeight: 2,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Play/Pause button
                IconButton(
                  icon: Icon(
                    _ttsState == TtsState.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                  ),
                  onPressed: _toggleTts,
                  iconSize: 28,
                ),
                const SizedBox(width: 8),
                // Title
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _currentSummary.title,
                        style: TextStyle(
                          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _ttsState == TtsState.playing ? 'Playing...' : 'Paused',
                        style: TextStyle(
                          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                // Stop button
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
                  onPressed: _stopTts,
                  iconSize: 24,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkdownContent(BuildContext context, String content, bool isDark) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Markdown content
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: MarkdownBody(
                    data: content,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      h1: Theme.of(context).textTheme.headlineMedium,
                      h2: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontSize: 20,
                            height: 1.4,
                          ),
                      h3: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontSize: 18,
                          ),
                      p: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            height: 1.7,
                          ),
                      listBullet: Theme.of(context).textTheme.bodyLarge,
                      blockquote: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          ),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                            width: 4,
                          ),
                        ),
                      ),
                      blockquotePadding: const EdgeInsets.only(left: 16),
                      code: TextStyle(
                        backgroundColor: isDark
                            ? AppTheme.darkSurface
                            : AppTheme.lightCardBorder.withAlpha(127),
                        color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: isDark ? AppTheme.darkSurface : const Color(0xFFF8F9FC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
                        ),
                      ),
                      codeblockPadding: const EdgeInsets.all(16),
                      horizontalRuleDecoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
                          ),
                        ),
                      ),
                      a: TextStyle(
                        color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    onTapLink: (text, href, title) async {
                      if (href != null) {
                        final uri = Uri.parse(href);
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      }
                    },
                  ),
                ),
                // Read original article link - prominent CTA
                if (_currentSummary.originalUrl != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _openOriginalArticle,
                        borderRadius: BorderRadius.circular(16),
                        child: Ink(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: isDark
                                  ? [Colors.blue.shade800, Colors.blue.shade900]
                                  : [Colors.blue.shade500, Colors.blue.shade700],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.blue.withAlpha(isDark ? 50 : 80),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.article_outlined,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    'Read full article on ${_extractSourceName(_currentSummary.originalUrl!)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Feedback widget
                FeedbackWidget(articleUrl: _currentSummary.url),
                // Navigation between articles
                if (_hasPrevious || _hasNext)
                  _buildNavigationControls(context, isDark),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNavigationControls(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(
            color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
          ),
          const SizedBox(height: 16),
          Text(
            'MORE BRIEFINGS',
            style: TextStyle(
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_hasPrevious)
                Expanded(
                  child: _buildNavButton(
                    context,
                    isDark,
                    isNext: false,
                    title: widget.allSummaries![_currentIndex - 1].title,
                    onTap: () => _navigateTo(_currentIndex - 1),
                  ),
                ),
              if (_hasPrevious && _hasNext) const SizedBox(width: 12),
              if (_hasNext)
                Expanded(
                  child: _buildNavButton(
                    context,
                    isDark,
                    isNext: true,
                    title: widget.allSummaries![_currentIndex + 1].title,
                    onTap: () => _navigateTo(_currentIndex + 1),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavButton(
    BuildContext context,
    bool isDark, {
    required bool isNext,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: isNext ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isNext) ...[
                  Icon(
                    Icons.arrow_back_rounded,
                    size: 14,
                    color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                  ),
                  const SizedBox(width: 4),
                ],
                Text(
                  isNext ? 'Next' : 'Previous',
                  style: TextStyle(
                    color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isNext) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 14,
                    color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                fontSize: 13,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: isNext ? TextAlign.end : TextAlign.start,
            ),
          ],
        ),
      ),
    );
  }
}
