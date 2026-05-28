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
  /// Which prompt version generated this summary (e.g., "v1", "v2")
  final String? promptVersion;
  /// Eval score from automated quality evaluation (0.0–1.0, normalized)
  final double? evalScore;

  Summary({
    required this.date,
    required this.url,
    required this.title,
    required this.summarySnippet,
    this.originalUrl,
    this.model,
    this.selectedBy,
    this.promptVersion,
    this.evalScore,
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
      promptVersion: json['prompt_version'] as String?,
      evalScore: (json['eval_score'] as num?)?.toDouble(),
    );
  }
}

/// Available LLM models for summaries
enum LlmModel {
  gemini('gemini-3.1-pro-preview', 'Gemini'),
  openai('gpt-5.2-2025-12-11', 'OpenAI'),
  claude('claude-opus-4-8', 'Claude');

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

    // Match by exact model ID, vendor name, or vendor prefix (backwards compat)
    return LlmModel.values.firstWhere(
      (m) => m.matchesId(id),
      orElse: () => LlmModel.gemini,
    );
  }

  /// Check if this model matches a given model string.
  ///
  /// Matches by exact ID, vendor name, vendor prefix (e.g. `claude-opus-4-8`
  /// matches the `claude` vendor), or model-family prefix taken from the
  /// canonical ID (e.g. `gpt-6` matches OpenAI, whose vendor name is `openai`
  /// but whose IDs are `gpt-*`). This lets new model versions be recognized
  /// without a client update.
  bool matchesId(String? modelStr) {
    if (modelStr == null) return false;
    final family = id.split('-').first;
    return modelStr == id ||
        modelStr == vendor ||
        modelStr.startsWith('$vendor-') ||
        modelStr.startsWith('$family-');
  }
}
