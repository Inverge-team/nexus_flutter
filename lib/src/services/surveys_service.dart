import 'package:flutter/foundation.dart';

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import '../surveys/survey_models.dart';

/// In-product surveys. Fetches the surveys a user is eligible for, decides which
/// to show (auto-show for popover/banner types + event triggers), and submits
/// answers. The rendering is done by `NexusSurveyOverlay` (default UI) or your
/// own widget driven by `NexusSurveyController`.
class NexusSurveys {
  NexusSurveys(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  /// The survey currently requested to display (null when none). The overlay
  /// listens to this.
  final ValueNotifier<NexusSurvey?> current = ValueNotifier<NexusSurvey?>(null);

  List<NexusSurvey> _active = const [];
  final Set<String> _shown = {};

  /// All surveys the user is currently eligible for.
  List<NexusSurvey> get active => List.unmodifiable(_active);

  /// Fetch eligible surveys from the server (targeting/sampling/capping applied).
  Future<List<NexusSurvey>> fetch() async {
    try {
      final props = <String, Object?>{..._cfg.defaultProperties, ..._id.traits};
      final res = await _http.post('/partner/surveys/active', {
        if (_id.distinctId != null) 'distinctId': _id.distinctId,
        'deviceKey': _id.deviceKey,
        if (props.isNotEmpty) 'properties': props,
        if (_id.deviceContext['osType'] != null) 'osType': _id.deviceContext['osType'],
      });
      final list = (res?['surveys'] as List?) ?? const [];
      _active = list.map(NexusSurvey.fromJson).toList();
      NexusLog.debug('surveys: ${_active.length} eligible');
      if (_cfg.surveyAutoShow) _showNextEligible(null);
    } catch (e) {
      NexusLog.warn('surveys fetch failed: $e');
    }
    return _active;
  }

  /// Called when an analytics event fires — shows a survey gated on that event.
  void onEvent(String name) {
    if (current.value != null || !_cfg.surveyAutoShow) return;
    _showNextEligible(name);
  }

  void _showNextEligible(String? triggeredEvent) {
    if (current.value != null) return;
    for (final s in _active) {
      if (_shown.contains(s.id)) continue;
      if (s.type != 'popover' && s.type != 'banner') continue;
      final events = s.trigger?.events ?? const [];
      if (events.isEmpty) {
        if (triggeredEvent != null) continue; // untriggered surveys show on fetch
        _present(s);
        return;
      }
      if (triggeredEvent != null && events.contains(triggeredEvent)) {
        _present(s);
        return;
      }
    }
  }

  void _present(NexusSurvey survey) {
    _shown.add(survey.id);
    current.value = survey;
    NexusLog.info('surveys: showing "${survey.name}"');
  }

  /// Present a specific survey now (e.g. from a "Give feedback" button).
  void show(NexusSurvey survey) => _present(survey);

  /// Remove the current survey from the screen (called by the UI when done).
  void close() => current.value = null;

  NexusSurvey? byId(String id) {
    for (final s in _active) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Submit a response (partial, complete, or dismissed). Best-effort.
  Future<void> respond(
    NexusSurvey survey,
    Map<String, Object?> answers, {
    bool completed = false,
    bool dismissed = false,
  }) async {
    await _http.post('/partner/surveys/responses', {
      'surveyId': survey.id,
      'answers': answers,
      if (survey.resumeResponseId != null) 'responseId': survey.resumeResponseId,
      if (completed) 'completed': true,
      if (dismissed) 'dismissed': true,
      if (survey.iterationKey != null) 'iterationKey': survey.iterationKey,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      ..._id.wireContext,
    });
  }

  void dispose() => current.dispose();
}
