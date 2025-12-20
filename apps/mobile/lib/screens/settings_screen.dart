import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/reading_history.dart';
import '../services/user_service.dart';
import '../services/notification_service.dart';
import '../services/cache_service.dart';
import '../services/build_info.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserPreferences _prefs;
  bool _notificationsAvailable = false;

  @override
  void initState() {
    super.initState();
    _prefs = UserService.getPreferences();
    _checkNotificationStatus();
  }

  Future<void> _checkNotificationStatus() async {
    final enabled = await NotificationService.areNotificationsEnabled();
    setState(() {
      _notificationsAvailable = enabled;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        children: [
          // Notifications Section
          _buildSectionHeader(context, 'Notifications'),
          _buildSwitchTile(
            context,
            title: 'Push Notifications',
            subtitle: _notificationsAvailable
                ? 'Receive alerts for new briefings'
                : 'Enable in system settings',
            value: _prefs.notificationsEnabled && _notificationsAvailable,
            onChanged: _notificationsAvailable
                ? (value) async {
                    setState(() {
                      _prefs.notificationsEnabled = value;
                    });
                    await UserService.setNotificationsEnabled(value);
                    if (value) {
                      await NotificationService.subscribeToTopic('daily_briefings');
                    } else {
                      await NotificationService.unsubscribeFromTopic('daily_briefings');
                    }
                  }
                : null,
            icon: Icons.notifications_rounded,
          ),
          _buildSwitchTile(
            context,
            title: 'Daily Briefing',
            subtitle: 'Get notified when new briefings are available',
            value: _prefs.dailyBriefingEnabled,
            onChanged: _prefs.notificationsEnabled
                ? (value) async {
                    setState(() {
                      _prefs.dailyBriefingEnabled = value;
                    });
                    await UserService.setDailyBriefingEnabled(value);
                  }
                : null,
            icon: Icons.schedule_rounded,
          ),

          const SizedBox(height: 16),

          // Reading Section
          _buildSectionHeader(context, 'Reading'),
          _buildActionTile(
            context,
            title: 'Reading History',
            subtitle: '${UserService.getReadingHistory().length} articles read',
            icon: Icons.history_rounded,
            onTap: () => _showReadingHistory(context),
          ),

          const SizedBox(height: 16),

          // Storage Section
          _buildSectionHeader(context, 'Storage'),
          _buildActionTile(
            context,
            title: 'Clear Cache',
            subtitle: 'Remove downloaded articles',
            icon: Icons.cleaning_services_rounded,
            onTap: () => _showClearCacheDialog(context),
          ),
          _buildActionTile(
            context,
            title: 'Clear Reading History',
            subtitle: 'Remove all reading history',
            icon: Icons.delete_outline_rounded,
            onTap: () => _showClearHistoryDialog(context),
          ),

          const SizedBox(height: 16),

          // About Section
          _buildSectionHeader(context, 'About'),
          _buildActionTile(
            context,
            title: 'About Eng Pulse',
            subtitle: BuildInfo.fullVersion,
            icon: Icons.info_outline_rounded,
            onTap: () => _showAboutDialog(context),
          ),
          _buildActionTile(
            context,
            title: 'Build',
            subtitle: '${BuildInfo.gitCommit} (${BuildInfo.buildTime})',
            icon: Icons.code_rounded,
            onTap: () {
              Clipboard.setData(ClipboardData(text: BuildInfo.gitCommit));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Commit hash copied')),
              );
            },
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSwitchTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required IconData icon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple)
              .withAlpha(25),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
          size: 20,
        ),
      ),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeTrackColor: (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple).withAlpha(150),
        activeThumbColor: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
      ),
    );
  }

  Widget _buildActionTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple)
              .withAlpha(25),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple,
          size: 20,
        ),
      ),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
      ),
      onTap: onTap,
    );
  }

  void _showReadingHistory(BuildContext context) {
    final history = UserService.getReadingHistory();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Reading History',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: history.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.history_rounded,
                              size: 48,
                              color: isDark
                                  ? AppTheme.darkTextTertiary
                                  : AppTheme.lightTextTertiary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No reading history yet',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: history.length,
                        itemBuilder: (context, index) {
                          final item = history[index];
                          return ListTile(
                            title: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(item.date),
                            trailing: item.feedback != null
                                ? Icon(
                                    item.feedback == 1
                                        ? Icons.thumb_up_rounded
                                        : Icons.thumb_down_rounded,
                                    size: 18,
                                    color: item.feedback == 1
                                        ? Colors.green
                                        : Colors.red,
                                  )
                                : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showClearCacheDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Cache?'),
        content: const Text(
          'This will remove all downloaded articles. You\'ll need an internet connection to read them again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await CacheService.clearAll();
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cache cleared')),
              );
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showClearHistoryDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear History?'),
        content: const Text(
          'This will remove all your reading history and feedback.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await UserService.clearHistory();
              if (!context.mounted) return;
              Navigator.pop(context);
              setState(() {}); // Refresh the count
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('History cleared')),
              );
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Eng Pulse',
      applicationVersion: BuildInfo.fullVersion,
      applicationIcon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppTheme.primaryPurple,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.bolt_rounded,
          color: Colors.white,
          size: 28,
        ),
      ),
      children: [
        const SizedBox(height: 16),
        const Text(
          'Daily software engineering briefings curated by AI.',
        ),
        const SizedBox(height: 8),
        const Text(
          'One article. One summary. Zero noise.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }
}
