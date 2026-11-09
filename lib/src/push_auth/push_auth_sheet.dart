import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../nexus.dart';
import 'push_auth_service.dart';

/// The built-in approval sheet: one screen per method (tap, match the number,
/// code display), the request details, where it came from, a live expiry
/// countdown, and "This wasn't me". Closes itself when another device answers
/// or the request expires.
///
/// ```dart
/// Nexus.instance.pushAuth.requests.listen((r) {
///   final ctx = navigatorKey.currentContext;
///   if (ctx != null) NexusPushAuthSheet.show(ctx, r);
/// });
/// ```
///
/// Build your own UI from [NexusPushAuthRequest] instead if you prefer — the
/// security comes from `approve()` / `deny()`, not from this widget.
class NexusPushAuthSheet extends StatefulWidget {
  const NexusPushAuthSheet({super.key, required this.request, this.appName});

  final NexusPushAuthRequest request;

  /// Shown in the header ("Sign in to `appName`?"). Defaults to "Is this you?".
  final String? appName;

  /// Show the sheet; resolves with the result (null when dismissed / expired).
  static Future<NexusPushAuthResult?> show(BuildContext context, NexusPushAuthRequest request, {String? appName}) {
    return showModalBottomSheet<NexusPushAuthResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => NexusPushAuthSheet(request: request, appName: appName),
    );
  }

  @override
  State<NexusPushAuthSheet> createState() => _NexusPushAuthSheetState();
}

class _NexusPushAuthSheetState extends State<NexusPushAuthSheet> {
  Timer? _tick;
  StreamSubscription<String>? _closedSub;
  bool _busy = false;
  String? _error;
  String? _code; // code_display: shown after approval
  final _typed = TextEditingController();

  NexusPushAuthRequest get r => widget.request;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (r.isExpired && _code == null) {
        Navigator.of(context).maybePop();
      } else {
        setState(() {});
      }
    });
    if (Nexus.isInitialized) {
      _closedSub = Nexus.instance.pushAuth.closed.where((id) => id == r.id).listen((_) {
        if (mounted && _code == null) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _closedSub?.cancel();
    _typed.dispose();
    super.dispose();
  }

  Future<void> _run(Future<NexusPushAuthResult> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await action();
      if (!mounted) return;
      if (res.code != null) {
        HapticFeedback.mediumImpact();
        setState(() => _code = res.code);
        return;
      }
      HapticFeedback.lightImpact();
      Navigator.of(context).pop(res);
    } on NexusPushAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.code) {
            'cancelled' => null, // the user closed the biometric prompt — stay on the sheet
            'key_invalidated' => 'Your fingerprints or face changed since this phone was set up. Set it up again to keep approving.',
            'lockout' => 'Too many attempts. Unlock your phone with its PIN, then try again.',
            'challenge_not_pending' => 'This request was already answered or has expired.',
            'network' => 'No connection. Check your internet and try again.',
            _ => 'Something went wrong (${e.reason ?? e.code}).',
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final left = r.expiresAt.difference(DateTime.now());
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.verified_user_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.appName != null ? 'Sign in to ${widget.appName}?' : 'Is this you?', style: t.textTheme.titleLarge)),
            if (_code == null)
              Text(left.isNegative ? 'expired' : '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.outline, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          const SizedBox(height: 14),
          Text(r.message, style: t.textTheme.titleMedium),
          if (r.fields.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final f in r.fields)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(width: 110, child: Text(f.label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.outline))),
                  Expanded(child: Text(f.value, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                ]),
              ),
          ],
          if (r.context.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.public, size: 16, color: t.colorScheme.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [r.context['device'], r.context['location'], r.context['ip']].whereType<String>().join(' · '),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.outline),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 20),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
            ),
          if (!r.isSupported)
            Text('This request needs a newer version of the app. Update it, then try again.', style: t.textTheme.bodyMedium)
          else if (_code != null)
            _codeView(t)
          else
            _methodView(t),
          if (_code == null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busy ? null : () => _run(() => r.deny(fraud: true)),
              icon: Icon(Icons.report_outlined, color: t.colorScheme.error),
              label: Text('This wasn’t me', style: TextStyle(color: t.colorScheme.error)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _methodView(ThemeData t) {
    switch (r.method) {
      case 'number_match':
        if (r.numberEntry == 'type') {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Enter the number shown on your screen', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            TextField(
              controller: _typed,
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              maxLength: r.numberDigits,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: t.textTheme.headlineMedium?.copyWith(letterSpacing: 8),
              decoration: const InputDecoration(counterText: '', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy || _typed.text.length != r.numberDigits ? null : () => _run(() => r.approve(number: _typed.text)),
              child: const Text('Approve'),
            ),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Tap the number shown on your screen', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Row(children: [
            for (final n in r.numberChoices)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: _busy ? null : () => _run(() => r.approve(number: n)),
                    child: Text(n, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          TextButton(onPressed: _busy ? null : () => _run(() => r.deny()), child: const Text('None of these — deny')),
        ]);
      case 'code_display':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Approve to see a code, then type it on your screen.', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          _approveDeny(),
        ]);
      default:
        return _approveDeny();
    }
  }

  Widget _approveDeny() => Row(children: [
        Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _run(() => r.deny()), child: const Text('Deny'))),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: _busy ? null : () => _run(() => r.approve()),
            child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Approve'),
          ),
        ),
      ]);

  Widget _codeView(ThemeData t) {
    final code = _code!;
    final spaced = code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Type this code on your screen', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
        child: Text(spaced, textAlign: TextAlign.center, style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 6)),
      ),
      const SizedBox(height: 12),
      FilledButton.tonal(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
    ]);
  }
}
