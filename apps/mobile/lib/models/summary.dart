class Summary {
  final String date;
  final String url;
  final String title;
  final String summarySnippet;
  final String? originalUrl;

  Summary({
    required this.date,
    required this.url,
    required this.title,
    required this.summarySnippet,
    this.originalUrl,
  });

  factory Summary.fromJson(Map<String, dynamic> json) {
    return Summary(
      date: json['date'] as String,
      url: json['url'] as String,
      title: json['title'] as String,
      summarySnippet: json['summary_snippet'] as String,
      originalUrl: json['original_url'] as String?,
    );
  }
}
