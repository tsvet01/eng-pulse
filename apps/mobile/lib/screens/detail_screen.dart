import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/cached_summary.dart';
import '../models/summary.dart';
import '../services/api_service.dart';
import '../services/cache_service.dart';
import '../services/connectivity_service.dart';
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
  late Future<String> _contentFuture;
  late CachedSummary _currentSummary;
  late int _currentIndex;
  bool _isCached = false;

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
  }

  void _loadCurrentArticle() {
    _isCached = CacheService.hasContent(_currentSummary.url);
    _contentFuture = _apiService.fetchMarkdown(_currentSummary.url);
    UserService.addToHistory(_currentSummary);
  }

  void _navigateTo(int index) {
    if (widget.allSummaries == null) return;
    setState(() {
      _currentIndex = index;
      _currentSummary = widget.allSummaries![index];
      _loadCurrentArticle();
    });
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

    return Scaffold(
      body: CustomScrollView(
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
                        Text(
                          _extractSourceName(_currentSummary.originalUrl!),
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
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
                  // Title
                  Text(
                    _currentSummary.title,
                    style: Theme.of(context).textTheme.headlineMedium,
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

                // Update cached state after content loads
                if (!_isCached) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        _isCached = true;
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
                // Read original article link
                if (_currentSummary.originalUrl != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: OutlinedButton.icon(
                      onPressed: _openOriginalArticle,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: Text('Read full article on ${_extractSourceName(_currentSummary.originalUrl!)}'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                        side: BorderSide(
                          color: (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple).withAlpha(100),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
