import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/cached_summary.dart';
import '../models/summary.dart';
import '../services/api_service.dart';
import '../services/connectivity_service.dart';
import '../services/cache_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import '../widgets/summary_card.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/empty_state.dart';
import '../widgets/offline_banner.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _apiService = ApiService();
  late Future<List<CachedSummary>> _summariesFuture;
  bool _isRefreshing = false;
  bool _isOnline = true;
  StreamSubscription<bool>? _connectivitySubscription;
  late LlmModel _selectedModel;
  List<LlmModel> _availableModels = [];

  @override
  void initState() {
    super.initState();
    _isOnline = ConnectivityService.isOnline;
    _selectedModel = LlmModel.fromId(UserService.getSelectedModel());
    _summariesFuture = _loadSummaries();

    // Listen to connectivity changes
    _connectivitySubscription = ConnectivityService.onConnectivityChanged.listen((isOnline) {
      if (!mounted) return;
      setState(() {
        _isOnline = isOnline;
      });

      // Refresh when coming back online
      if (isOnline) {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<List<CachedSummary>> _loadSummaries() async {
    final allSummaries = await _apiService.fetchSummaries();

    // Determine available models from the data
    final modelIds = allSummaries
        .map((s) => s.model)
        .whereType<String>()
        .toSet();

    if (mounted) {
      setState(() {
        _availableModels = modelIds.isEmpty
            ? [LlmModel.gemini] // Default if no model field (backwards compat)
            : modelIds.map((id) => LlmModel.fromId(id)).toList();

        // Ensure selected model is available
        if (!_availableModels.contains(_selectedModel) && _availableModels.isNotEmpty) {
          _selectedModel = _availableModels.first;
        }
      });
    }

    // Filter by selected model (or show all if no model field)
    final summaries = allSummaries.where((s) {
      if (s.model == null) return true; // Backwards compat
      return _selectedModel.matchesId(s.model);
    }).toList();

    // Pre-cache content for offline reading in background
    if (ConnectivityService.isOnline && summaries.isNotEmpty) {
      _apiService.preCacheContent(summaries);
    }

    return summaries;
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _isRefreshing = true;
    });

    try {
      final allSummaries = await _apiService.fetchSummaries(forceRefresh: true);

      // Filter by selected model (same logic as _loadSummaries)
      final summaries = allSummaries.where((s) {
        if (s.model == null) return true; // Backwards compat
        return _selectedModel.matchesId(s.model);
      }).toList();

      // Pre-cache content
      if (ConnectivityService.isOnline && summaries.isNotEmpty) {
        _apiService.preCacheContent(summaries);
      }

      if (!mounted) return;
      setState(() {
        _summariesFuture = Future.value(summaries);
        _isRefreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _summariesFuture = Future.error(e);
        _isRefreshing = false;
      });
    }
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inDays == 0) {
        return 'Today';
      } else if (difference.inDays == 1) {
        return 'Yesterday';
      } else if (difference.inDays < 7) {
        return DateFormat('EEEE').format(date);
      } else {
        return DateFormat('MMM d, yyyy').format(date);
      }
    } catch (e) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Offline banner
            if (!_isOnline) const OfflineBanner(),

            // Main content
            Expanded(
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverAppBar(
                      floating: true,
                      snap: true,
                      title: Row(
                        children: [
                          Icon(
                            Icons.bolt_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 28,
                          ),
                          const SizedBox(width: 8),
                          const Text('Eng Pulse'),
                        ],
                      ),
                      actions: [
                        // Model selector (only show if multiple models available)
                        if (_availableModels.length > 1)
                          _buildModelSelector(context),
                        IconButton(
                          icon: AnimatedRotation(
                            turns: _isRefreshing ? 1 : 0,
                            duration: const Duration(milliseconds: 500),
                            child: const Icon(Icons.refresh_rounded),
                          ),
                          onPressed: _isRefreshing ? null : _refresh,
                          tooltip: 'Refresh',
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings_rounded),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const SettingsScreen(),
                              ),
                            );
                          },
                          tooltip: 'Settings',
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ];
                },
                body: FutureBuilder<List<CachedSummary>>(
                  future: _summariesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const ShimmerLoading();
                    }

                    if (snapshot.hasError) {
                      // Try to show cached data on error (filtered by selected model)
                      final cached = CacheService.getCachedSummaries()
                          .where((s) => s.model == null || _selectedModel.matchesId(s.model))
                          .toList();
                      if (cached.isNotEmpty) {
                        return _buildList(cached);
                      }

                      return ErrorState(
                        message: 'Failed to load briefings.\nPlease check your connection.',
                        onRetry: _refresh,
                      );
                    }

                    final summaries = snapshot.data ?? [];

                    if (summaries.isEmpty) {
                      return EmptyState(
                        title: 'No briefings yet',
                        subtitle: 'Check back tomorrow for your daily engineering digest.',
                        icon: Icons.auto_stories_outlined,
                        onRetry: _refresh,
                      );
                    }

                    return _buildList(summaries);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelSelector(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple)
            .withAlpha(25),
        borderRadius: BorderRadius.circular(20),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LlmModel>(
          value: _selectedModel,
          icon: Icon(
            Icons.expand_more_rounded,
            size: 20,
            color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
          ),
          style: TextStyle(
            color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          dropdownColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          items: _availableModels.map((model) {
            return DropdownMenuItem(
              value: model,
              child: Text(model.displayName),
            );
          }).toList(),
          onChanged: (model) async {
            if (model != null && model != _selectedModel) {
              await UserService.setSelectedModel(model.id);
              setState(() {
                _selectedModel = model;
                _summariesFuture = _loadSummaries();
              });
            }
          },
        ),
      ),
    );
  }

  Widget _buildList(List<CachedSummary> summaries) {
    // Group summaries by date category
    final grouped = _groupByDateCategory(summaries);

    return RefreshIndicator(
      onRefresh: _refresh,
      color: Theme.of(context).colorScheme.primary,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 20),
        itemCount: grouped.length,
        itemBuilder: (context, index) {
          final item = grouped[index];

          return switch (item) {
            _SectionHeader(:final title, :final isFirst) =>
              _buildSectionHeader(context, title, isFirst),
            _SummaryItem(:final summary, :final originalIndex) => SummaryCard(
              summary: summary,
              formattedDate: _formatDate(summary.date),
              showDateChip: false, // Date shown in section header
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => DetailScreen(
                      summary: summary,
                      allSummaries: summaries,
                      currentIndex: originalIndex,
                    ),
                  ),
                );
                // Refresh to update read status
                if (mounted) setState(() {});
              },
            ),
          };
        },
      ),
    );
  }

  List<_GroupedItem> _groupByDateCategory(List<CachedSummary> summaries) {
    final result = <_GroupedItem>[];
    String? currentCategory;

    for (int i = 0; i < summaries.length; i++) {
      final summary = summaries[i];
      final category = _getDateCategory(summary.date);

      if (category != currentCategory) {
        result.add(_SectionHeader(title: category, isFirst: currentCategory == null));
        currentCategory = category;
      }
      result.add(_SummaryItem(summary: summary, originalIndex: i));
    }

    return result;
  }

  String _getDateCategory(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final articleDate = DateTime(date.year, date.month, date.day);
      final difference = today.difference(articleDate).inDays;

      if (difference == 0) return 'Today';
      if (difference == 1) return 'Yesterday';
      if (difference < 7) return 'This Week';
      return 'Earlier';
    } catch (e) {
      return 'Earlier';
    }
  }

  Widget _buildSectionHeader(BuildContext context, String title, bool isFirst) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isToday = title == 'Today';

    return Padding(
      padding: EdgeInsets.fromLTRB(20, isFirst ? 8 : 24, 20, 8),
      child: Row(
        children: [
          if (isToday) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: isToday
                  ? (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple)
                  : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sealed class for type-safe grouped list items
sealed class _GroupedItem {}

class _SectionHeader extends _GroupedItem {
  final String title;
  final bool isFirst;
  _SectionHeader({required this.title, required this.isFirst});
}

class _SummaryItem extends _GroupedItem {
  final CachedSummary summary;
  final int originalIndex;
  _SummaryItem({required this.summary, required this.originalIndex});
}
