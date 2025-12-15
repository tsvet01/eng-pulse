import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/cached_summary.dart';
import '../services/api_service.dart';
import '../services/cache_service.dart';
import '../services/connectivity_service.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/feedback_widget.dart';
import '../services/user_service.dart';

class DetailScreen extends StatefulWidget {
  final CachedSummary summary;

  const DetailScreen({super.key, required this.summary});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final ApiService _apiService = ApiService();
  late Future<String> _contentFuture;
  bool _isCached = false;

  @override
  void initState() {
    super.initState();
    _isCached = CacheService.hasContent(widget.summary.url);
    _contentFuture = _apiService.fetchMarkdown(widget.summary.url);

    // Add to reading history
    UserService.addToHistory(widget.summary);
  }

  void _retry() {
    setState(() {
      _contentFuture = _apiService.fetchMarkdown(widget.summary.url);
    });
  }

  Future<void> _openOriginalArticle() async {
    final originalUrl = widget.summary.originalUrl;
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
      '${widget.summary.title}\n\n${widget.summary.summarySnippet}\n\nRead on Eng Pulse',
      subject: widget.summary.title,
    );
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
                  // Date chip and offline/cached indicator
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
                          widget.summary.date,
                          style: TextStyle(
                            color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
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
                    widget.summary.title,
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
                  final cached = CacheService.getCachedContent(widget.summary.url);
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
          child: Markdown(
      data: content,
      padding: const EdgeInsets.all(20),
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
        FeedbackWidget(articleUrl: widget.summary.url),
      ],
    );
  }
}
