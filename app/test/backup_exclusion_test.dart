// iCloud 备份排除（早前批次）单元：通道调用形状+失败容错。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/backup_exclusion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('companion/appinfo');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('两目录各发起一次排除（应用支持+文档）', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    final saved = Map.of(debugDirProviders);
    addTearDown(() => debugDirProviders..clear()..addAll(saved));
    debugDirProviders.clear();
    // （级联段不能以 [ 开头——Dart 语法限制，普通语句替代。）
    debugDirProviders['getApplicationSupportDirectory'] =
        () async => '/var/mobile/X/support';
    debugDirProviders['getApplicationDocumentsDirectory'] =
        () async => '/var/mobile/X/docs';

    await excludeDirsFromICloudBackup();

    expect(
      calls.map((c) => c.method),
      everyElement('excludeFromiCloudBackup'),
    );
    expect(calls.map((c) => c.arguments), [
      {'path': '/var/mobile/X/support'},
      {'path': '/var/mobile/X/docs'},
    ]);
  });

  test('原生回 false / 通道抛错：不外抛（备份面不阻塞启动）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
    final saved = Map.of(debugDirProviders);
    addTearDown(() => debugDirProviders..clear()..addAll(saved));
    debugDirProviders.clear();
    debugDirProviders['getApplicationSupportDirectory'] = () async => '/x';
    debugDirProviders['getApplicationDocumentsDirectory'] =
        () => throw StateError('boom');

    await expectLater(excludeDirsFromICloudBackup(), completes);
  });
}
