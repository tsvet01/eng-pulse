import 'package:hive/hive.dart';

part 'reading_history.g.dart';

@HiveType(typeId: 1)
class ReadingHistoryItem extends HiveObject {
  @HiveField(0)
  final String url;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String date;

  @HiveField(3)
  final DateTime readAt;

  @HiveField(4)
  int? feedback; // -1 = thumbs down, 0 = neutral, 1 = thumbs up

  ReadingHistoryItem({
    required this.url,
    required this.title,
    required this.date,
    required this.readAt,
    this.feedback,
  });
}

@HiveType(typeId: 2)
class UserPreferences extends HiveObject {
  @HiveField(0)
  bool notificationsEnabled;

  @HiveField(1)
  bool dailyBriefingEnabled;

  @HiveField(2)
  String preferredTime; // e.g., "08:00"

  @HiveField(3)
  List<String> preferredTopics;

  @HiveField(4)
  String selectedModel; // 'gemini', 'openai', 'claude'

  UserPreferences({
    this.notificationsEnabled = true,
    this.dailyBriefingEnabled = true,
    this.preferredTime = "08:00",
    List<String>? preferredTopics,
    this.selectedModel = 'gemini',
  }) : preferredTopics = preferredTopics ?? [];
}
