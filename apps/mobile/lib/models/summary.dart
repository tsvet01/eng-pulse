class Summary {
  final String date;
  final String url;
  final String title;
  final String summarySnippet;
  final String? originalUrl;
  final String? model;

  Summary({
    required this.date,
    required this.url,
    required this.title,
    required this.summarySnippet,
    this.originalUrl,
    this.model,
  });

  factory Summary.fromJson(Map<String, dynamic> json) {
    return Summary(
      date: json['date'] as String,
      url: json['url'] as String,
      title: json['title'] as String,
      summarySnippet: json['summary_snippet'] as String,
      originalUrl: json['original_url'] as String?,
      model: json['model'] as String?,
    );
  }
}

/// Available LLM models for summaries
enum LlmModel {
  gemini('gemini', 'Gemini'),
  openai('openai', 'OpenAI'),
  claude('claude', 'Claude');

  final String id;
  final String displayName;
  const LlmModel(this.id, this.displayName);

  static LlmModel fromId(String? id) {
    return LlmModel.values.firstWhere(
      (m) => m.id == id,
      orElse: () => LlmModel.gemini,
    );
  }
}
