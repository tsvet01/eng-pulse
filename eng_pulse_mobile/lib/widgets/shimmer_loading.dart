import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ShimmerLoading extends StatefulWidget {
  const ShimmerLoading({super.key});

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    _animation = Tween<double>(begin: -2, end: 2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ListView.builder(
          padding: const EdgeInsets.only(top: 8, bottom: 20),
          itemCount: 4,
          itemBuilder: (context, index) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildShimmerBox(
                      width: 80,
                      height: 24,
                      isDark: isDark,
                      borderRadius: 20,
                    ),
                    const SizedBox(height: 12),
                    _buildShimmerBox(
                      width: double.infinity,
                      height: 22,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 8),
                    _buildShimmerBox(
                      width: MediaQuery.of(context).size.width * 0.6,
                      height: 22,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 12),
                    _buildShimmerBox(
                      width: double.infinity,
                      height: 16,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 6),
                    _buildShimmerBox(
                      width: double.infinity,
                      height: 16,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 6),
                    _buildShimmerBox(
                      width: MediaQuery.of(context).size.width * 0.4,
                      height: 16,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildShimmerBox({
    required double width,
    required double height,
    required bool isDark,
    double borderRadius = 8,
  }) {
    final baseColor = isDark
        ? AppTheme.darkCardBorder.withAlpha(127)
        : AppTheme.lightCardBorder;
    final highlightColor = isDark
        ? AppTheme.darkCardBorder
        : AppTheme.lightCardBorder.withAlpha(76);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment(_animation.value - 1, 0),
          end: Alignment(_animation.value + 1, 0),
          colors: [
            baseColor,
            highlightColor,
            baseColor,
          ],
        ),
      ),
    );
  }
}
