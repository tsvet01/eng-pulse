import 'package:flutter/material.dart';
import '../models/cached_summary.dart';
import '../services/cache_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';

class SummaryCard extends StatefulWidget {
  final CachedSummary summary;
  final VoidCallback onTap;
  final String formattedDate;
  final bool showDateChip;
  final int? readingTimeMinutes;

  const SummaryCard({
    super.key,
    required this.summary,
    required this.onTap,
    required this.formattedDate,
    this.showDateChip = true,
    this.readingTimeMinutes,
  });

  /// Estimate reading time based on word count (avg 200 wpm)
  static int estimateReadingTime(String? content) {
    if (content == null || content.isEmpty) return 3; // default
    final wordCount = content.split(RegExp(r'\s+')).length;
    return (wordCount / 200).ceil().clamp(1, 15);
  }

  @override
  State<SummaryCard> createState() => _SummaryCardState();
}

class _SummaryCardState extends State<SummaryCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _animationController.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _animationController.reverse();
  }

  void _onTapCancel() {
    _animationController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isCached = CacheService.hasContent(widget.summary.url);
    final isRead = UserService.hasRead(widget.summary.url);
    final readTime = widget.readingTimeMinutes ??
        SummaryCard.estimateReadingTime(widget.summary.cachedContent);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isRead
                        ? (isDark
                            ? AppTheme.darkCardBorder.withAlpha(100)
                            : AppTheme.lightCardBorder.withAlpha(150))
                        : (isDark
                            ? AppTheme.darkCardBorder
                            : AppTheme.lightCardBorder),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(
                          (_scaleAnimation.value < 1.0 ? 10 : 20).toInt()),
                      blurRadius: _scaleAnimation.value < 1.0 ? 4 : 8,
                      offset: Offset(0, _scaleAnimation.value < 1.0 ? 1 : 2),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Metadata row: date chip, reading time, read indicator
                      Row(
                        children: [
                          if (widget.showDateChip) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: (isDark
                                        ? AppTheme.primaryPurpleDark
                                        : AppTheme.primaryPurple)
                                    .withAlpha(25),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                widget.formattedDate,
                                style: TextStyle(
                                  color: isDark
                                      ? AppTheme.primaryPurpleDark
                                      : AppTheme.primaryPurple,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          // Reading time
                          Icon(
                            Icons.schedule_rounded,
                            size: 14,
                            color: isDark
                                ? AppTheme.darkTextTertiary
                                : AppTheme.lightTextTertiary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$readTime min read',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppTheme.darkTextTertiary
                                  : AppTheme.lightTextTertiary,
                            ),
                          ),
                          const Spacer(),
                          // Read indicator
                          if (isRead)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: (isDark
                                        ? Colors.green.shade700
                                        : Colors.green.shade600)
                                    .withAlpha(30),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 12,
                                    color: isDark
                                        ? Colors.green.shade300
                                        : Colors.green.shade700,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Read',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.green.shade300
                                          : Colors.green.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (isCached)
                            Icon(
                              Icons.cloud_done_outlined,
                              size: 16,
                              color: isDark
                                  ? AppTheme.darkTextTertiary
                                  : AppTheme.lightTextTertiary,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Title with Hero transition
                      Hero(
                        tag: 'title-${widget.summary.url}',
                        flightShuttleBuilder: (flightContext, animation,
                            flightDirection, fromHeroContext, toHeroContext) {
                          return Material(
                            color: Colors.transparent,
                            child: toHeroContext.widget,
                          );
                        },
                        child: Text(
                          widget.summary.title,
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    color: isRead
                                        ? (isDark
                                            ? AppTheme.darkTextSecondary
                                            : AppTheme.lightTextSecondary)
                                        : null,
                                  ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Snippet
                      Text(
                        widget.summary.summarySnippet,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: isRead
                                  ? (isDark
                                      ? AppTheme.darkTextTertiary
                                      : AppTheme.lightTextTertiary)
                                  : null,
                            ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
