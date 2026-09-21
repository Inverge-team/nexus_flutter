import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:shared_preferences/shared_preferences.dart';

/// HEADLESS call-media entrypoint. Runs in a Flutter engine that our native
/// [NexusCallForegroundService] hosts AFTER the user answers in the system call
/// UI — the app's own UI is never launched. It creates the callee leg, connects
/// LiveKit audio, and stays until the call ends. This is what makes answering
/// behave like a normal phone call: audio, no app.
///
/// Registered natively as the Dart entrypoint `nexusVoiceHeadlessMain`.
/// Config (base URL + API key) is persisted by the main app via
/// [persistVoiceConfig] so this isolate — which shares no state with the app —
/// can talk to the backend.
@pragma('vm:entry-point')
void nexusVoiceHeadlessMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: avoid_print
  print('[NexusHeadless] entrypoint started');
  _HeadlessCall().run();
}

const _channel = MethodChannel('nexus/voice_headless');
const _kBase = 'nexus_voice_base';
const _kKey = 'nexus_voice_key';
const _kOs = 'nexus_voice_os';
const _kOsV = 'nexus_voice_osv';

/// Persist the minimum the headless isolate needs to bring a call up. Called by
/// the main app on voice init (it has the config; the isolate does not).
Future<void> persistVoiceConfig({
  required String base,
  required String apiKey,
  String? osType,
  String? osVersion,
}) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBase, base);
    await p.setString(_kKey, apiKey);
    if (osType != null) await p.setString(_kOs, osType);
    if (osVersion != null) await p.setString(_kOsV, osVersion);
  } catch (_) {/* best effort */}
}

class _HeadlessCall {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  String? _callId;
  bool _ended = false;

  void run() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'disconnect') await _end();
      return null;
    });
    _start();
  }

  Future<void> _start() async {
    try {
      // Native hands us the call id once we signal ready.
      final callId = await _channel.invokeMethod<String>('ready');
      _log('ready -> callId=$callId');
      if (callId == null || callId.isEmpty) { await _end(); return; }
      _callId = callId;

      final p = await SharedPreferences.getInstance();
      final base = p.getString(_kBase);
      final key = p.getString(_kKey);
      _log('config base=$base keyLen=${key?.length}');
      if (base == null || key == null) { await _end(); return; }
      final headers = {
        'content-type': 'application/json',
        'x-api-key': key,
        if (p.getString(_kOs) != null) 'x-client-os': p.getString(_kOs)!,
        if (p.getString(_kOsV) != null) 'x-client-os-version': p.getString(_kOsV)!,
      };

      // 1) Create OUR (callee) media leg and get a LiveKit join token.
      final legRes = await http
          .post(
            Uri.parse('$base/partner/voice/legs'),
            headers: headers,
            body: jsonEncode({
              'sessionId': callId,
              'role': 'callee',
              'endpointType': 'webrtc',
              'direction': 'inbound',
            }),
          )
          .timeout(const Duration(seconds: 15));
      _log('legs POST -> ${legRes.statusCode}');
      if (legRes.statusCode < 200 || legRes.statusCode >= 300) { await _end(); return; }
      final body = jsonDecode(legRes.body) as Map<String, dynamic>;
      final leg = body['leg'] as Map<String, dynamic>?;
      final join = body['join'] as Map<String, dynamic>?;
      final legId = leg?['id'] as String?;
      final url = join?['url'] as String?;
      final token = join?['token'] as String?;
      _log('leg=$legId url=$url tokenLen=${token?.length}');
      if (legId == null || url == null || token == null) { await _end(); return; }

      // 2) Join the media room (audio only) and open the mic.
      final room = lk.Room(
        roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
      );
      final listener = room.createListener();
      listener
        ..on<lk.RoomDisconnectedEvent>((_) => _end())
        ..on<lk.ParticipantDisconnectedEvent>((_) {
          // The other party left an established call → hang up.
          if (room.remoteParticipants.isEmpty) _end();
        });
      _room = room;
      _listener = listener;
      _log('connecting livekit…');
      await room.connect(url, token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      _log('livekit connected, mic on');

      // 3) Mark the leg answered so the backend/caller see us connected.
      await http.post(
        Uri.parse('$base/partner/voice/legs/answer'),
        headers: headers,
        body: jsonEncode({'legId': legId}),
      );
      _log('answered leg=$legId');
    } catch (e, st) {
      _log('ERROR $e\n$st');
      await _end();
    }
  }

  void _log(String m) {
    // ignore: avoid_print
    print('[NexusHeadless] $m');
  }

  Future<void> _end() async {
    if (_ended) return;
    _ended = true;
    try {
      await _listener?.dispose();
      await _room?.disconnect();
      await _room?.dispose();
    } catch (_) {}
    try {
      await _channel.invokeMethod('callEnded', {'callId': _callId});
    } catch (_) {}
  }
}
