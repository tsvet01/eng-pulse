import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/cached_summary.dart';
import '../services/api_service.dart';
import '../services/connectivity_service.dart';
import '../services/cache_service.dart';
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

  @override
  void initState() {
    super.initState();
    _isOnline = ConnectivityService.isOnline;
    _summariesFuture = _loadSummaries();

    // Listen to connectivity changes
    _connectivitySubscription = ConnectivityService.onConnectivityChanged.listen((isOnline) {
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
    final summaries = await _apiService.fetchSummaries();

    // Pre-cache content for offline reading in background
    if (ConnectivityService.isOnline && summaries.isNotEmpty) {
      _apiService.preCacheContent(summaries);
    }

    return summaries;
  }

  Future<void> _refresh() async {
    setState(() {
      _isRefreshing = true;
    });

    try {
      final summaries = await _apiService.fetchSummaries(forceRefresh: true);

      // Pre-cache content
      if (ConnectivityService.isOnline && summaries.isNotEmpty) {
        _apiService.preCacheContent(summaries);
      }

      setState(() {
        _summariesFuture = Future.value(summaries);
        _isRefreshing = false;
      });
    } catch (e) {
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
                      // Try to show cached data on error
                      final cached = CacheService.getCachedSummaries();
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

  Widget _buildList(List<CachedSummary> summaries) {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: Theme.of(context).colorScheme.primary,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 20),
        itemCount: summaries.length,
        itemBuilder: (context, index) {
          final summary = summaries[index];
          return SummaryCard(
            summary: summary,
            formattedDate: _formatDate(summary.date),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DetailScreen(summary: summary),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
