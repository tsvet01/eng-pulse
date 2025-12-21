class Summary {
  final String date;
  final String url;
  final String title;
  final String summarySnippet;
  final String? originalUrl;
  /// Which model generated the summary
  final String? model;
  /// Which model selected this article from the candidates
  final String? selectedBy;

  Summary({
    required this.date,
    required this.url,
    required this.title,
    required this.summarySnippet,
    this.originalUrl,
    this.model,
    this.selectedBy,
  });

  factory Summary.fromJson(Map<String, dynamic> json) {
    return Summary(
      date: json['date'] as String,
      url: json['url'] as String,
      title: json['title'] as String,
      summarySnippet: json['summary_snippet'] as String,
      originalUrl: json['original_url'] as String?,
      model: json['model'] as String?,
      selectedBy: json['selected_by'] as String?,
    );
  }
}

/// Available LLM models for summaries
enum LlmModel {
  gemini('gemini-3-pro-preview', 'Gemini'),
  openai('gpt-5.2-2025-12-11', 'OpenAI'),
  claude('claude-opus-4-5', 'Claude');

  final String id;
  final String displayName;
  const LlmModel(this.id, this.displayName);

  /// Get the vendor/provider name (gemini, openai, claude)
  String get vendor {
    switch (this) {
      case LlmModel.gemini:
        return 'gemini';
      case LlmModel.openai:
        return 'openai';
      case LlmModel.claude:
        return 'claude';
    }
  }

  static LlmModel fromId(String? id) {
    if (id == null) return LlmModel.gemini;

    // Match by exact model ID or vendor name (backwards compat)
    return LlmModel.values.firstWhere(
      (m) => m.id == id || m.vendor == id,
      orElse: () => LlmModel.gemini,
    );
  }
}
