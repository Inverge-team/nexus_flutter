import 'package:flutter/material.dart';

import '../nexus.dart';
import 'survey_controller.dart';
import 'survey_models.dart';
import 'survey_view.dart';

/// Fully replace the survey UI. You receive the [NexusSurveyController]; render
/// whatever you want and drive it (answers, next/back, complete, dismiss, close).
typedef NexusSurveyBuilder = Widget Function(BuildContext context, NexusSurveyController controller);

/// Hosts the currently-active survey above your app. Add it via
/// `MaterialApp.builder` so it has a Material/Overlay/MediaQuery ancestor:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => NexusSurveyOverlay(child: child!),
///   // ...
/// )
/// ```
///
/// Bring your own UI with [surveyBuilder] (whole card) or [questionBuilder] (per
/// question) — otherwise the built-in [NexusSurveyView] is used.
class NexusSurveyOverlay extends StatefulWidget {
  const NexusSurveyOverlay({
    super.key,
    required this.child,
    this.surveyBuilder,
    this.questionBuilder,
  });

  final Widget child;
  final NexusSurveyBuilder? surveyBuilder;
  final NexusQuestionBuilder? questionBuilder;

  @override
  State<NexusSurveyOverlay> createState() => _NexusSurveyOverlayState();
}

class _NexusSurveyOverlayState extends State<NexusSurveyOverlay> {
  ValueNotifier<NexusSurvey?>? _current;
  NexusSurveyController? _controller;

  @override
  void initState() {
    super.initState();
    if (Nexus.isInitialized) {
      _current = Nexus.instance.surveys.current;
      _current!.addListener(_onCurrent);
      _onCurrent();
    }
  }

  @override
  void dispose() {
    _current?.removeListener(_onCurrent);
    super.dispose();
  }

  void _onCurrent() {
    final survey = _current?.value;
    if (survey == null) {
      _controller = null;
    } else if (_controller?.survey.id != survey.id) {
      final surveys = Nexus.instance.surveys;
      _controller = NexusSurveyController(survey, surveys.respond)..onClose = surveys.close;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Stack(
      children: [
        widget.child,
        if (controller != null)
          Positioned.fill(
            child: SafeArea(
              child: Align(
                alignment: _alignment(controller.survey.position),
                child: widget.surveyBuilder?.call(context, controller) ??
                    NexusSurveyView(controller: controller, questionBuilder: widget.questionBuilder),
              ),
            ),
          ),
      ],
    );
  }

  Alignment _alignment(String? position) {
    switch (position) {
      case 'top':
        return Alignment.topCenter;
      case 'center':
        return Alignment.center;
      case 'left':
        return Alignment.bottomLeft;
      case 'right':
        return Alignment.bottomRight;
      case 'bottom':
      default:
        return Alignment.bottomCenter;
    }
  }
}
