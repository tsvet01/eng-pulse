import 'package:hive/hive.dart';

part 'cached_summary.g.dart';

@HiveType(typeId: 0)
class CachedSummary extends HiveObject {
  @HiveField(0)
  final String date;

  @HiveField(1)
  final String url;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String summarySnippet;

  @HiveField(4)
  String? cachedContent;

  @HiveField(5)
  DateTime? lastUpdated;

  @HiveField(6)
  final String? originalUrl;

  CachedSummary({
    required this.date,
    required this.url,
    required this.title,
    required this.summarySnippet,
    this.cachedContent,
    this.lastUpdated,
    this.originalUrl,
  });

  bool get hasCachedContent => cachedContent != null && cachedContent!.isNotEmpty;

  CachedSummary copyWith({
    String? date,
    String? url,
    String? title,
    String? summarySnippet,
    String? cachedContent,
    DateTime? lastUpdated,
    String? originalUrl,
  }) {
    return CachedSummary(
      date: date ?? this.date,
      url: url ?? this.url,
      title: title ?? this.title,
      summarySnippet: summarySnippet ?? this.summarySnippet,
      cachedContent: cachedContent ?? this.cachedContent,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      originalUrl: originalUrl ?? this.originalUrl,
    );
  }
}
