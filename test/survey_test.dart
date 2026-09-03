import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/nexus.dart';

NexusSurvey _survey() => NexusSurvey.fromJson({
  'id': 's1',
  'name': 'NPS survey',
  'type': 'popover',
  'appearance': {'thankYouMessage': 'Cheers!'},
  'questions': [
    {'id': 'q1', 'type': 'nps', 'label': 'How likely?', 'required': true},
    {
      'id': 'q2',
      'type': 'single_choice',
      'label': 'Why?',
      'choices': [
        {'value': 'fast'},
        'slow',
      ],
    },
  ],
});

void main() {
  test('parses a survey from JSON', () {
    final s = _survey();
    expect(s.id, 's1');
    expect(s.questions.length, 2);
    expect(s.questions[0].type, 'nps');
    expect(s.questions[0].required, isTrue);
    expect(s.questions[1].choices.map((c) => c.value), ['fast', 'slow']);
    expect(s.thankYouMessage, 'Cheers!');
    expect(s.showProgressBar, isTrue); // default
  });

  test('controller walks steps and submits a completed response', () async {
    Map<String, Object?>? submitted;
    bool? wasCompleted;
    final c = NexusSurveyController(_survey(), (
      survey,
      answers, {
      completed = false,
      dismissed = false,
    }) async {
      submitted = answers;
      wasCompleted = completed;
    });

    expect(c.currentQuestion!.id, 'q1');
    expect(c.canAdvance, isFalse); // required, unanswered

    c.setAnswer('q1', 9);
    expect(c.canAdvance, isTrue);
    expect(c.isLast, isFalse);

    await c.next();
    expect(c.currentQuestion!.id, 'q2');
    expect(c.isLast, isTrue);

    c.setAnswer('q2', 'fast');
    await c.next(); // completes

    expect(wasCompleted, isTrue);
    expect(submitted!['q1'], 9);
    expect(submitted!['q2'], 'fast');
    expect(c.isDone, isTrue);
  });

  test('controller dismiss submits a dismissal', () async {
    bool? wasDismissed;
    final c = NexusSurveyController(_survey(), (
      survey,
      answers, {
      completed = false,
      dismissed = false,
    }) async {
      wasDismissed = dismissed;
    });
    await c.dismiss();
    expect(wasDismissed, isTrue);
    expect(c.isDone, isTrue);
  });

  testWidgets(
    'default view renders the question; custom builder overrides it',
    (tester) async {
      final c = NexusSurveyController(
        _survey(),
        (s, a, {completed = false, dismissed = false}) async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NexusSurveyView(controller: c)),
        ),
      );
      expect(find.text('How likely?'), findsOneWidget);

      final c2 = NexusSurveyController(
        _survey(),
        (s, a, {completed = false, dismissed = false}) async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NexusSurveyView(
              controller: c2,
              questionBuilder: (ctx, ctrl, q) => const Text('CUSTOM WIDGET'),
            ),
          ),
        ),
      );
      expect(find.text('CUSTOM WIDGET'), findsOneWidget);
    },
  );
}
