import 'package:flutter/material.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';

class FeedbackWidget extends StatefulWidget {
  final String articleUrl;

  const FeedbackWidget({super.key, required this.articleUrl});

  @override
  State<FeedbackWidget> createState() => _FeedbackWidgetState();
}

class _FeedbackWidgetState extends State<FeedbackWidget> {
  int? _feedback;

  @override
  void initState() {
    super.initState();
    _feedback = UserService.getFeedback(widget.articleUrl);
  }

  Future<void> _setFeedback(int value) async {
    // Toggle off if same value
    final newValue = _feedback == value ? null : value;

    setState(() {
      _feedback = newValue;
    });

    if (newValue != null) {
      await UserService.setFeedback(widget.articleUrl, newValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        border: Border(
          top: BorderSide(
            color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Was this helpful?',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          _buildFeedbackButton(
            context,
            icon: Icons.thumb_up_rounded,
            isSelected: _feedback == 1,
            onTap: () => _setFeedback(1),
            selectedColor: Colors.green,
          ),
          const SizedBox(width: 8),
          _buildFeedbackButton(
            context,
            icon: Icons.thumb_down_rounded,
            isSelected: _feedback == -1,
            onTap: () => _setFeedback(-1),
            selectedColor: Colors.red,
          ),
        ],
      ),
    );
  }

  Widget _buildFeedbackButton(
    BuildContext context, {
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required Color selectedColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? selectedColor.withAlpha(30)
                : (isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder)
                    .withAlpha(50),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? selectedColor
                  : (isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isSelected
                ? selectedColor
                : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
          ),
        ),
      ),
    );
  }
}
