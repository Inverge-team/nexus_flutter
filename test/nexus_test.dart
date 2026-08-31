import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/nexus.dart';
import 'package:nexus/nexus_platform_interface.dart';
import 'package:nexus/nexus_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNexusPlatform
    with MockPlatformInterfaceMixin
    implements NexusPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final NexusPlatform initialPlatform = NexusPlatform.instance;

  test('$MethodChannelNexus is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNexus>());
  });

  test('getPlatformVersion', () async {
    Nexus nexusPlugin = Nexus();
    MockNexusPlatform fakePlatform = MockNexusPlatform();
    NexusPlatform.instance = fakePlatform;

    expect(await nexusPlugin.getPlatformVersion(), '42');
  });
}
