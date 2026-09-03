import 'package:flutter/material.dart';

import 'survey_controller.dart';
import 'survey_models.dart';

/// Override the rendering of a single question. Return your own widget; read the
/// current value with `controller.answerFor(question.id)` and write it with
/// `controller.setAnswer(...)` / `controller.toggleChoice(...)`.
typedef NexusQuestionBuilder = Widget Function(
  BuildContext context,
  NexusSurveyController controller,
  NexusSurveyQuestion question,
);

/// The built-in survey card. Renders one question at a time with progress, a
/// thank-you screen, and default widgets per question type. Pass a
/// [questionBuilder] to override individual questions, or replace the whole card
/// via `NexusSurveyOverlay(surveyBuilder: ...)`.
class NexusSurveyView extends StatefulWidget {
  const NexusSurveyView({
    super.key,
    required this.controller,
    this.questionBuilder,
  });

  final NexusSurveyController controller;
  final NexusQuestionBuilder? questionBuilder;

  @override
  State<NexusSurveyView> createState() => _NexusSurveyViewState();
}

class _NexusSurveyViewState extends State<NexusSurveyView> {
  bool _thankYouScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final survey = c.survey;
    final theme = Theme.of(context);
    final accent =
        _hexColor(survey.primaryColorHex) ?? theme.colorScheme.primary;

    if (c.isDone) {
      if (survey.showThankYou) {
        if (!_thankYouScheduled) {
          _thankYouScheduled = true;
          Future.delayed(const Duration(milliseconds: 2200), () {
            if (mounted) c.close();
          });
        }
        return _card(child: _thankYou(theme, survey));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => c.close());
      return const SizedBox.shrink();
    }

    final q = c.currentQuestion;
    if (q == null) return const SizedBox.shrink();

    return _card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  survey.name,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
              InkWell(
                onTap: () => c.dismiss(),
                child: Icon(Icons.close, size: 18, color: theme.hintColor),
              ),
            ],
          ),
          if (survey.showProgressBar && c.totalSteps > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: c.progress,
                  color: accent,
                  minHeight: 4,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            q.label,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (q.description != null && q.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                q.description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
          const SizedBox(height: 14),
          widget.questionBuilder?.call(context, c, q) ??
              _defaultQuestion(context, c, q, accent),
          const SizedBox(height: 14),
          Row(
            children: [
              if (c.step > 0)
                TextButton(onPressed: c.back, child: const Text('Back')),
              const Spacer(),
              ElevatedButton(
                onPressed: (c.canAdvance && !c.isSubmitting)
                    ? () => c.next()
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                ),
                child: Text(_nextLabel(c, q, survey)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _nextLabel(
    NexusSurveyController c,
    NexusSurveyQuestion q,
    NexusSurvey survey,
  ) {
    if (q.type == 'link') return q.buttonText ?? 'Continue';
    if (c.isLast) return survey.submitButtonText ?? 'Submit';
    return 'Next';
  }

  Widget _card({required Widget child}) {
    return Card(
      margin: const EdgeInsets.all(12),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  Widget _thankYou(ThemeData theme, NexusSurvey survey) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 40),
        const SizedBox(height: 10),
        if (survey.thankYouTitle != null)
          Text(survey.thankYouTitle!, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          survey.thankYouMessage,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _defaultQuestion(
    BuildContext context,
    NexusSurveyController c,
    NexusSurveyQuestion q,
    Color accent,
  ) {
    switch (q.type) {
      case 'open':
      case 'email':
        return _TextAnswer(
          key: ValueKey(q.id),
          initial: c.answerFor(q.id) as String?,
          hint: q.type == 'email' ? 'you@example.com' : 'Type your answer…',
          multiline: q.type == 'open',
          onChanged: (v) => c.setAnswer(q.id, v),
        );
      case 'single_choice':
        // Uses RadioListTile's groupValue/onChanged (deprecated in Flutter 3.32
        // in favour of a RadioGroup ancestor). Kept for compatibility with the
        // package's declared minimum (`flutter: >=3.3.0`), where RadioGroup does
        // not exist yet.
        final selectedChoice = c.answerFor(q.id) as String?;
        return Column(
          children: q.choices
              .map(
                (ch) => RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: accent,
                  value: ch.value,
                  // ignore: deprecated_member_use
                  groupValue: selectedChoice,
                  // ignore: deprecated_member_use
                  onChanged: (v) => c.setAnswer(q.id, v),
                  title: Text(ch.display),
                ),
              )
              .toList(),
        );
      case 'multiple_choice':
        final selected =
            (c.answerFor(q.id) as List?)?.cast<String>() ?? const [];
        return Column(
          children: q.choices
              .map(
                (ch) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: accent,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: selected.contains(ch.value),
                  onChanged: (_) => c.toggleChoice(q.id, ch.value),
                  title: Text(ch.display),
                ),
              )
              .toList(),
        );
      case 'boolean':
        final v = c.answerFor(q.id);
        return Row(
          children: [
            Expanded(
              child: _pill(
                'Yes',
                v == true,
                accent,
                () => c.setAnswer(q.id, true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _pill(
                'No',
                v == false,
                accent,
                () => c.setAnswer(q.id, false),
              ),
            ),
          ],
        );
      case 'rating':
        return _scale(
          c,
          q,
          accent,
          q.scaleMin ?? 1,
          q.scaleMax ?? 5,
          star: q.display == 'star',
          emoji: q.display == 'emoji',
        );
      case 'nps':
        return _scale(c, q, accent, 0, 10);
      case 'link':
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _scale(
    NexusSurveyController c,
    NexusSurveyQuestion q,
    Color accent,
    int min,
    int max, {
    bool star = false,
    bool emoji = false,
  }) {
    final current = (c.answerFor(q.id) as num?)?.toInt();
    final emojis = ['😡', '🙁', '😐', '🙂', '😍'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (int i = min; i <= max; i++)
              InkWell(
                onTap: () => c.setAnswer(q.id, i),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: star || emoji ? 40 : 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: current == i ? accent.withValues(alpha: 0.15) : null,
                    border: Border.all(
                      color: current == i
                          ? accent
                          : Colors.grey.withValues(alpha: 0.4),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: star
                      ? Icon(
                          current != null && i <= current
                              ? Icons.star
                              : Icons.star_border,
                          color: accent,
                          size: 20,
                        )
                      : emoji
                      ? Text(
                          emojis[((i - min) * (emojis.length - 1) / (max - min))
                              .round()],
                          style: const TextStyle(fontSize: 18),
                        )
                      : Text(
                          '$i',
                          style: TextStyle(
                            fontWeight: current == i
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                ),
              ),
          ],
        ),
        if (q.lowerLabel != null || q.upperLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  q.lowerLabel ?? '',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                Text(
                  q.upperLabel ?? '',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _pill(String label, bool selected, Color accent, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.15) : null,
          border: Border.all(
            color: selected ? accent : Colors.grey.withValues(alpha: 0.4),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// Text input that owns its editing state (so rebuilds don't drop focus).
class _TextAnswer extends StatefulWidget {
  const _TextAnswer({
    super.key,
    this.initial,
    required this.hint,
    required this.multiline,
    required this.onChanged,
  });
  final String? initial;
  final String hint;
  final bool multiline;
  final ValueChanged<String> onChanged;

  @override
  State<_TextAnswer> createState() => _TextAnswerState();
}

class _TextAnswerState extends State<_TextAnswer> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: widget.onChanged,
      minLines: widget.multiline ? 2 : 1,
      maxLines: widget.multiline ? 4 : 1,
      keyboardType: widget.multiline
          ? TextInputType.multiline
          : TextInputType.text,
      decoration: InputDecoration(
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

Color? _hexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}
