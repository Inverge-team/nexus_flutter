import 'package:flutter/foundation.dart';

import 'survey_models.dart';

/// Persists a response (partial or terminal). Wired to the surveys service.
typedef SurveySubmit = Future<void> Function(
  NexusSurvey survey,
  Map<String, Object?> answers, {
  bool completed,
  bool dismissed,
});

/// Drives one survey: holds answers, step position, validity, and submit/dismiss.
///
/// This is the seam for **custom UIs** — pass your own widget to the overlay and
/// drive it entirely from this controller (`currentQuestion`, `setAnswer`,
/// `next`, `back`, `complete`, `dismiss`, `progress`). It's a [ChangeNotifier],
/// so rebuild on changes.
class NexusSurveyController extends ChangeNotifier {
  NexusSurveyController(this.survey, this._submit) {
    answers.addAll(survey.resumeAnswers);
  }

  final NexusSurvey survey;
  final SurveySubmit _submit;

  /// Wired by the overlay to remove the survey from the screen. Call [close]
  /// from your UI when you're done presenting (e.g. after a thank-you).
  VoidCallback? onClose;

  void close() => onClose?.call();

  /// Answers keyed by question id (value type depends on question type).
  final Map<String, Object?> answers = {};

  int _step = 0;
  bool _done = false;
  bool _submitting = false;

  int get step => _step;
  int get totalSteps => survey.questions.length;
  bool get isDone => _done;
  bool get isSubmitting => _submitting;
  double get progress => totalSteps == 0 ? 1 : (_step + 1) / totalSteps;
  bool get isLast => _step + 1 >= totalSteps;

  NexusSurveyQuestion? get currentQuestion =>
      _step >= 0 && _step < survey.questions.length
      ? survey.questions[_step]
      : null;

  Object? answerFor(String questionId) => answers[questionId];

  void setAnswer(String questionId, Object? value) {
    answers[questionId] = value;
    notifyListeners();
  }

  /// Toggle a value within a multi-select answer.
  void toggleChoice(String questionId, String value) {
    final current =
        (answers[questionId] as List?)?.cast<String>() ?? <String>[];
    final next = [...current];
    next.contains(value) ? next.remove(value) : next.add(value);
    answers[questionId] = next;
    notifyListeners();
  }

  /// Whether the current (required) question has a valid answer.
  bool get canAdvance {
    final q = currentQuestion;
    if (q == null) return false;
    if (!q.required) return true;
    final a = answers[q.id];
    if (a == null) return false;
    if (a is String) return a.trim().isNotEmpty;
    if (a is List) return a.isNotEmpty;
    return true;
  }

  /// Advance to the next question, or complete on the last.
  Future<void> next() async {
    if (!canAdvance || _submitting) return;
    if (isLast) {
      await complete();
    } else {
      _step++;
      notifyListeners();
    }
  }

  void back() {
    if (_step > 0) {
      _step--;
      notifyListeners();
    }
  }

  Future<void> complete() async {
    if (_done || _submitting) return;
    _submitting = true;
    notifyListeners();
    await _submit(survey, Map.of(answers), completed: true);
    _submitting = false;
    _done = true;
    notifyListeners();
  }

  Future<void> dismiss() async {
    if (_done) return;
    _done = true;
    notifyListeners();
    await _submit(survey, Map.of(answers), dismissed: true);
  }
}
