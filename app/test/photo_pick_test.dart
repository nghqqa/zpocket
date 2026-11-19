// 相册直选旅程（早前批次）：加号面板「照片」→ 相册多选 →
// PlatformFile 摄取管线（heic/heif 归一 jpg / 大小拦截 / 待传队列）。
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/ui/conversation_page.dart';
import 'package:zpocket/ui/voice_input_sheet.dart'
    show debugVoiceRecognitionAvailable;

/// 内存桩（PlatformFile 层）：相册选择后的形态——真 IO 桩在 testWidgets
/// 假区永不完成（教训），磁盘往返由 attachment 族的纯逻辑组
/// 真文件用例覆盖。
final class _MemImage extends PlatformFile {
  _MemImage(this.name, this.bytes);

  @override
  final String name;

  final Uint8List bytes;

  @override
  Uri get uri => Uri.parse('mem://$name');

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() async* {
    yield bytes;
  }

  @override
  XFile get xFile => throw UnimplementedError('测试桩不消费');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => debugVoiceRecognitionAvailable = true);
  tearDownAll(() => debugVoiceRecognitionAvailable = null);

  tearDown(() => ConversationPage.debugPickImages = null);

  Future<void> _pumpDraftPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final app = AppState()..loaded = true;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(
          home: Scaffold(body: ConversationPage(sessionId: null, title: '草稿')),
        ),
      ),
    );
    await tester.pump();
  }

  test('照片名归一：heic/heif → jpg（重编码后名实一致）', () {
    expect(
      ConversationPage.normalizePhotoFileName('IMG_0001.heic'),
      'IMG_0001.jpg',
    );
    expect(
      ConversationPage.normalizePhotoFileName('照片 2.HEIC'),
      '照片 2.jpg',
    );
    expect(
      ConversationPage.normalizePhotoFileName('x.heif'),
      'x.jpg',
    );
    expect(ConversationPage.normalizePhotoFileName('screenshot.png'),
        'screenshot.png');
    expect(ConversationPage.normalizePhotoFileName('无扩展名'), '无扩展名',
        reason: '非 heic/heif 名一概不动');
  });

  testWidgets('照片入口：选中即进待传队列（与文件附件同管线）', (tester) async {
    await _pumpDraftPage(tester);
    // image mime 走缩略图格（挂起态不显名，'待发' 遮罩在场）；非 image
    // mime 走文件芯片（Text.rich 文件名+状态后缀）。两种形态都过。
    ConversationPage.debugPickImages = () async => [
      _MemImage('IMG_0001.jpg', Uint8List(64)),
      _MemImage('说明.pdf', Uint8List(64)),
    ];

    await tester.tap(find.byKey(const ValueKey('add-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-photo')));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((w) {
        if (w.key is! ValueKey<String>) return false;
        final v = (w.key as ValueKey<String>).value;
        return v.startsWith('pending-attachment-att-') &&
            !v.contains('-remove-') &&
            !v.contains('-annotate-') &&
            !v.contains('-retry-');
      }),
      findsNWidgets(2),
      reason: '两张均进入待传区（缩略格+文件芯片各一；remove/annotate/'
          'retry 子键排除）',
    );
    expect(
      find.textContaining('说明.pdf', findRichText: true),
      findsOneWidget,
      reason: '文件芯片显示文件名（富文本含状态后缀）',
    );
    expect(find.text('待发'), findsWidgets, reason: '挂起态遮罩在场');
    expect(tester.takeException(), isNull);
  });

  testWidgets('相册抛错：人话提示不崩溃（等待期退页同守卫）', (tester) async {
    await _pumpDraftPage(tester);
    ConversationPage.debugPickImages = () async => throw StateError('boom');

    await tester.tap(find.byKey(const ValueKey('add-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-photo')));
    await tester.pumpAndSettle();

    expect(find.text('相册不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
