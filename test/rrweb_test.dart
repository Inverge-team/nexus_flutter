import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/replay/rrweb.dart';

void main() {
  test('full snapshot models a full-page <img>', () {
    final full = Rrweb.fullSnapshot(
      dataUri: 'data:image/png;base64,AAA',
      width: 100,
      height: 200,
    );
    expect(full['type'], 2);
    final node = (full['data'] as Map)['node'] as Map;
    expect(node['type'], 0); // Document
    final html = (node['childNodes'] as List)[1] as Map;
    final body = (html['childNodes'] as List)[1] as Map;
    final img = (body['childNodes'] as List)[0] as Map;
    expect(img['tagName'], 'img');
    expect(img['id'], Rrweb.imgId);
    expect((img['attributes'] as Map)['src'], 'data:image/png;base64,AAA');
  });

  test('frame is a mutation of the img src', () {
    final frame = Rrweb.frame(dataUri: 'data:image/png;base64,BBB');
    expect(frame['type'], 3);
    final data = frame['data'] as Map;
    expect(data['source'], 0); // Mutation
    final attr = (data['attributes'] as List).first as Map;
    expect(attr['id'], Rrweb.imgId);
    expect((attr['attributes'] as Map)['src'], 'data:image/png;base64,BBB');
  });

  test('meta carries viewport size', () {
    final meta = Rrweb.meta(href: 'app://', width: 411, height: 866);
    expect(meta['type'], 4);
    expect((meta['data'] as Map)['width'], 411);
    expect((meta['data'] as Map)['height'], 866);
  });

  test('pointer events map to rrweb interactions', () {
    expect((Rrweb.pointerDown(1, 2)['data'] as Map)['type'], 7); // TouchStart
    expect((Rrweb.pointerUp(1, 2)['data'] as Map)['type'], 9); // TouchEnd
    final move = Rrweb.pointerMove([Rrweb.position(3, 4)]);
    expect((move['data'] as Map)['source'], 6); // TouchMove
    expect(((move['data'] as Map)['positions'] as List).length, 1);
  });
}
