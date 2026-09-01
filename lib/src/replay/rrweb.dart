import 'dart:convert';

/// Builders for rrweb-compatible replay events.
///
/// Flutter has no DOM, so we model a screen as a single full-page `<img>` inside
/// a synthetic rrweb document: the first frame is a *full snapshot* of that DOM,
/// each subsequent frame is a *mutation* swapping the `<img>` `src` to the new
/// screenshot, and pointer events are standard rrweb interactions. The console's
/// rrweb-player then replays the session as screenshot playback with a live
/// pointer — no custom player needed.
///
/// rrweb reference: EventType (2=FullSnapshot, 3=IncrementalSnapshot, 4=Meta),
/// IncrementalSource (0=Mutation, 2=MouseInteraction, 6=TouchMove),
/// NodeType (0=Document, 1=DocumentType, 2=Element).
class Rrweb {
  Rrweb._();

  // Stable node ids for the synthetic DOM (rrweb requires unique ids per node).
  static const int docId = 1;
  static const int docTypeId = 2;
  static const int htmlId = 3;
  static const int headId = 4;
  static const int bodyId = 5;
  static const int imgId = 6;

  static int now() => DateTime.now().millisecondsSinceEpoch;

  /// Meta (type 4) — must be the first event; the player uses it to size itself.
  static Map<String, Object?> meta({
    required String href,
    required int width,
    required int height,
    int? timestamp,
  }) =>
      {
        'type': 4,
        'data': {'href': href, 'width': width, 'height': height},
        'timestamp': timestamp ?? now(),
      };

  /// Full snapshot (type 2): `html > body > img(src)`. Sent once per recording
  /// (and again after a resize).
  static Map<String, Object?> fullSnapshot({
    required String dataUri,
    required int width,
    required int height,
    int? timestamp,
  }) =>
      {
        'type': 2,
        'data': {
          'node': {
            'type': 0,
            'id': docId,
            'childNodes': [
              {'type': 1, 'id': docTypeId, 'name': 'html', 'publicId': '', 'systemId': ''},
              {
                'type': 2,
                'id': htmlId,
                'tagName': 'html',
                'attributes': <String, Object?>{},
                'childNodes': [
                  {
                    'type': 2,
                    'id': headId,
                    'tagName': 'head',
                    'attributes': <String, Object?>{},
                    'childNodes': <Object?>[],
                  },
                  {
                    'type': 2,
                    'id': bodyId,
                    'tagName': 'body',
                    'attributes': {'style': 'margin:0;padding:0;background:#000;'},
                    'childNodes': [_imgNode(dataUri, width, height)],
                  },
                ],
              },
            ],
          },
          'initialOffset': {'left': 0, 'top': 0},
        },
        'timestamp': timestamp ?? now(),
      };

  static Map<String, Object?> _imgNode(String dataUri, int w, int h) => {
        'type': 2,
        'id': imgId,
        'tagName': 'img',
        'attributes': {
          'src': dataUri,
          'width': '$w',
          'height': '$h',
          'style': 'display:block;width:${w}px;height:${h}px;',
        },
        'childNodes': <Object?>[],
      };

  /// Incremental frame (type 3, Mutation): swap the `<img>` `src`.
  static Map<String, Object?> frame({required String dataUri, int? timestamp}) => {
        'type': 3,
        'data': {
          'source': 0,
          'texts': <Object?>[],
          'attributes': [
            {
              'id': imgId,
              'attributes': {'src': dataUri},
            },
          ],
          'removes': <Object?>[],
          'adds': <Object?>[],
        },
        'timestamp': timestamp ?? now(),
      };

  /// Pointer down/up as rrweb MouseInteraction (TouchStart=7 / TouchEnd=9).
  static Map<String, Object?> pointerDown(double x, double y, {int? timestamp}) =>
      _interaction(7, x, y, timestamp);
  static Map<String, Object?> pointerUp(double x, double y, {int? timestamp}) =>
      _interaction(9, x, y, timestamp);

  /// A tap, as rrweb MouseInteraction Click=2 (what the inspector counts).
  static Map<String, Object?> click(double x, double y, {int? timestamp}) =>
      _interaction(2, x, y, timestamp);

  /// A console line (rrweb console plugin) — surfaces in the player's Console tab.
  static Map<String, Object?> consoleLog(String level, String message, {int? timestamp}) => {
        'type': 6,
        'data': {
          'plugin': 'rrweb/console@1',
          'payload': {
            'level': level,
            'trace': <Object?>[],
            'payload': [jsonEncode(message)],
          },
        },
        'timestamp': timestamp ?? now(),
      };

  /// A network request (rrweb network plugin) — surfaces in the Network tab.
  static Map<String, Object?> network({
    required String url,
    required String method,
    required int status,
    required num duration,
    num? size,
    int? startTime,
    int? timestamp,
  }) =>
      {
        'type': 6,
        'data': {
          'plugin': 'rrweb/network@1',
          'payload': {
            'requests': [
              {
                'url': url,
                'method': method,
                'status': status,
                'duration': duration,
                'startTime': startTime ?? (timestamp ?? now()),
                if (size != null) 'transferSize': size,
              },
            ],
          },
        },
        'timestamp': timestamp ?? now(),
      };

  static Map<String, Object?> _interaction(int type, double x, double y, int? timestamp) => {
        'type': 3,
        'data': {'source': 2, 'type': type, 'id': bodyId, 'x': x.round(), 'y': y.round()},
        'timestamp': timestamp ?? now(),
      };

  /// Pointer move — a batch of positions (rrweb TouchMove, source 6).
  static Map<String, Object?> pointerMove(List<Map<String, Object?>> positions, {int? timestamp}) => {
        'type': 3,
        'data': {'source': 6, 'positions': positions},
        'timestamp': timestamp ?? now(),
      };

  static Map<String, Object?> position(double x, double y, {int timeOffset = 0}) =>
      {'x': x.round(), 'y': y.round(), 'id': bodyId, 'timeOffset': timeOffset};
}
