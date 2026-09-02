/// Client-side survey models, parsed from `/partner/surveys/active`. Pure Dart
/// (no Flutter) so they can be used and tested without a widget tree.

class NexusSurveyChoice {
  const NexusSurveyChoice({required this.value, this.label, this.open = false});

  final String value;
  final String? label;
  final bool open;

  String get display => label ?? value;

  static NexusSurveyChoice fromJson(dynamic json) {
    if (json is String) return NexusSurveyChoice(value: json);
    final m = json as Map;
    return NexusSurveyChoice(
      value: '${m['value'] ?? ''}',
      label: m['label'] as String?,
      open: m['open'] == true,
    );
  }
}

class NexusSurveyQuestion {
  const NexusSurveyQuestion({
    required this.id,
    required this.type,
    required this.label,
    this.description,
    this.required = false,
    this.choices = const [],
    this.display,
    this.scaleMin,
    this.scaleMax,
    this.lowerLabel,
    this.upperLabel,
    this.buttonText,
    this.buttonUrl,
  });

  /// open | single_choice | multiple_choice | rating | nps | boolean | link | email
  final String type;
  final String id;
  final String label;
  final String? description;
  final bool required;
  final List<NexusSurveyChoice> choices;
  final String? display; // number | emoji | star
  final int? scaleMin;
  final int? scaleMax;
  final String? lowerLabel;
  final String? upperLabel;
  final String? buttonText;
  final String? buttonUrl;

  bool get isMultiSelect => type == 'multiple_choice';

  static NexusSurveyQuestion fromJson(Map<String, dynamic> m) {
    return NexusSurveyQuestion(
      id: '${m['id'] ?? ''}',
      type: '${m['type'] ?? 'open'}',
      label: '${m['label'] ?? ''}',
      description: m['description'] as String?,
      required: m['required'] == true,
      choices: (m['choices'] as List?)?.map(NexusSurveyChoice.fromJson).toList() ?? const [],
      display: m['display'] as String?,
      scaleMin: (m['scaleMin'] as num?)?.toInt(),
      scaleMax: (m['scaleMax'] as num?)?.toInt(),
      lowerLabel: m['lowerLabel'] as String?,
      upperLabel: m['upperLabel'] as String?,
      buttonText: m['buttonText'] as String?,
      buttonUrl: m['buttonUrl'] as String?,
    );
  }
}

class NexusSurveyTrigger {
  const NexusSurveyTrigger({this.events = const [], this.delaySeconds, this.minInterval, this.selector});

  final List<String> events;
  final int? delaySeconds;
  final int? minInterval;
  final String? selector;

  static NexusSurveyTrigger? fromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    return NexusSurveyTrigger(
      events: (m['events'] as List?)?.map((e) => '$e').toList() ?? const [],
      delaySeconds: (m['delaySeconds'] as num?)?.toInt(),
      minInterval: (m['minInterval'] as num?)?.toInt(),
      selector: m['selector'] as String?,
    );
  }
}

class NexusSurvey {
  const NexusSurvey({
    required this.id,
    required this.name,
    required this.type,
    required this.questions,
    this.appearance = const {},
    this.trigger,
    this.iterationKey,
    this.resumeResponseId,
    this.resumeAnswers = const {},
  });

  final String id;
  final String name;
  final String type; // popover | widget | banner | api | ...
  final List<NexusSurveyQuestion> questions;
  final Map<String, Object?> appearance;
  final NexusSurveyTrigger? trigger;
  final String? iterationKey;
  final String? resumeResponseId;
  final Map<String, Object?> resumeAnswers;

  // Appearance conveniences (safe defaults).
  String? get position => appearance['position'] as String?;
  String? get primaryColorHex => appearance['primaryColor'] as String?;
  String? get thankYouTitle => appearance['thankYouTitle'] as String?;
  String get thankYouMessage => (appearance['thankYouMessage'] as String?) ?? 'Thanks for your feedback!';
  bool get showThankYou => appearance['showThankYou'] as bool? ?? true;
  bool get showProgressBar => appearance['showProgressBar'] as bool? ?? true;
  String? get submitButtonText => appearance['submitButtonText'] as String?;

  static NexusSurvey fromJson(dynamic json) {
    final m = json as Map<String, dynamic>;
    final resume = m['resume'] as Map<String, dynamic>?;
    return NexusSurvey(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? ''}',
      type: '${m['type'] ?? 'popover'}',
      questions: (m['questions'] as List?)
              ?.map((q) => NexusSurveyQuestion.fromJson((q as Map).cast<String, dynamic>()))
              .toList() ??
          const [],
      appearance: (m['appearance'] as Map?)?.cast<String, Object?>() ?? const {},
      trigger: NexusSurveyTrigger.fromJson((m['trigger'] as Map?)?.cast<String, dynamic>()),
      iterationKey: m['iterationKey'] as String?,
      resumeResponseId: resume?['responseId'] as String?,
      resumeAnswers: (resume?['answers'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }
}
