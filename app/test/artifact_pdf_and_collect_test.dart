// 批 3：pdf-preview-collect-1 —— PDF 应用内预览与「收集产物」完成直达提示条。
// 覆盖：PDF 识别/魔数嗅探/16MiB 分块读取纯逻辑、ArtifactPdfPage 全旅程（多页翻页/
// 释放句柄/单页无翻页栏/单页失败重试/加密与损坏降级/英文 320dp 1.3x 无溢漏）、
// WorkflowRunDetailPage Android/iOS 平台门控、ConversationPage 收集产物直达条。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/pdf_preview_client.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/transport/channel_client.dart';
import 'package:zpocket/transport/companion_client.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/transport/rpc_frame_transport.dart';
import 'package:zpocket/ui/artifact_pdf_page.dart';
import 'package:zpocket/ui/conversation_page.dart';
import 'package:zpocket/ui/share_flow.dart'
    show ArtifactShareDiskPort, shareDisk;
import 'package:zpocket/ui/workflow_runs_page.dart';

/// 1×1 合法 PNG 字节常量，供 Image.memory 真解码。
final Uint8List _png1x1 = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 合法 PDF 头 + 二进制标识字节（sniffPdfMagic 为 true 且 looksBinaryContent 为 true）。
final Uint8List _samplePdfBytes = Uint8List.fromList([
  ...utf8.encode('%PDF-1.7\n%'),
  0xE2,
  0xE3,
  0xCF,
  0xD3,
  0x0A,
  0x00,
  ...utf8.encode('1 0 obj\n<<>>\nendobj\n%%EOF\n'),
]);

class _FakePdfBackend implements PdfPreviewBackend {
  int pageCount;
  Object? openError;
  final Map<int, List<Object?>> pageScripts = {};
  final Map<int, int> _renderCalls = {};
  final List<String> closedHandles = [];
  int _nextId = 0;
  int inFlightRenders = 0;
  int maxInFlightRenders = 0;
  Future<Uint8List> Function(int pageIndex)? onRenderAsync;

  Set<int> get renderedPages => _renderCalls.keys.toSet();
  int renderCallsFor(int pageIndex) => _renderCalls[pageIndex] ?? 0;

  _FakePdfBackend({this.pageCount = 3, this.openError});

  @override
  Future<PdfDocumentHandle> open(Uint8List bytes) async {
    if (openError != null) throw openError!;
    final id = 'pdf-handle-${++_nextId}';
    return PdfDocumentHandle(handle: id, pageCount: pageCount);
  }

  @override
  Future<Uint8List> renderPage(
    String handle,
    int pageIndex, {
    int maxWidth = 1440,
  }) async {
    final attempt = _renderCalls[pageIndex] ?? 0;
    _renderCalls[pageIndex] = attempt + 1;
    inFlightRenders++;
    if (inFlightRenders > maxInFlightRenders) {
      maxInFlightRenders = inFlightRenders;
    }
    try {
      if (onRenderAsync != null) {
        return await onRenderAsync!(pageIndex);
      }
      final script = pageScripts[pageIndex];
      if (script != null && attempt < script.length) {
        final step = script[attempt];
        if (step is Object && step is! Uint8List) throw step;
        if (step is Uint8List) return step;
      }
      return _png1x1;
    } finally {
      inFlightRenders--;
    }
  }

  @override
  Future<void> close(String handle) async {
    closedHandles.add(handle);
  }
}

class _MemShareDisk extends ArtifactShareDiskPort {
  final files = <String, List<int>>{};

  @override
  Future<void> ensureTarget(File target) async {}

  @override
  Future<void> writeBytes(File target, List<int> bytes) async {
    files[target.path] = bytes;
  }

  @override
  Future<List<int>> readHead(File target, [int limit = 1024]) async =>
      (files[target.path] ?? const <int>[]).take(limit).toList();

  @override
  Future<File> renameTo(File from, String newName) async {
    final bytes = files.remove(from.path);
    final moved = File(
      '${from.parent.path}${Platform.pathSeparator}$newName',
    );
    if (bytes != null) files[moved.path] = bytes;
    return moved;
  }
}

class _FakeBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-pdf';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _FakeSub implements ConversationSubscription {
  _FakeSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-pdf';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _CollectApp extends AppState {
  final _FakeSub sub = _FakeSub('s1');
  final List<String> sentTexts = [];
  List<Map<String, dynamic>> rpcRuns;
  Map<String, List<Map<String, dynamic>>> artifactsByRun;
  Uint8List pdfBytes;

  _CollectApp({
    List<Map<String, dynamic>>? initialRuns,
    List<Map<String, dynamic>>? rpcRuns,
    Map<String, List<Map<String, dynamic>>>? artifactsByRun,
    Uint8List? pdfBytes,
  }) : rpcRuns = rpcRuns ??
           const [
             {
               'runId': 'run-old',
               'toolCallId': 'tc-old',
               'label': '旧任务',
               'status': 'completed',
               'updatedAt': 1,
               'resumable': false,
             },
           ],
       artifactsByRun = artifactsByRun ??
           const {
             'run-1': [
               {
                 'id': 'art-pdf',
                 'kind': 'file',
                 'title': 'report.pdf',
                 'version': 1,
               },
             ],
             'run-new': [
               {
                 'id': 'art-new-1',
                 'kind': 'file',
                 'title': 'report.pdf',
                 'version': 1,
               },
               {
                 'id': 'art-new-2',
                 'kind': 'text',
                 'title': 'summary.txt',
                 'version': 1,
               },
             ],
           },
       pdfBytes = pdfBytes ?? _samplePdfBytes {
    uiPrefs.debugMarkLoadedForTest();
    sub.state.applySeed(
      ConversationSeed(
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '请整理文件'},
          {
            'rowId': 2,
            'kind': 'turnHeader',
            'state': 'completedSuccess',
            'entityId': 'e1',
          },
        ],
        logEpoch: 'e1',
        seq: 2,
        firstRowId: 1,
        totalCount: 2,
        snapshot: {
          'title': '产物收集测试',
          'control': {'phase': 'completedSuccess'},
          'workflowRuns': {
            'revision': 1,
            'runs': initialRuns ??
                const [
                  {
                    'runId': 'run-old',
                    'toolCallId': 'tc-old',
                    'status': 'completed',
                    'lastEventSequence': 10,
                    'artifacts': [
                      {'id': 'a-old', 'kind': 'text'},
                    ],
                  },
                ],
          },
        },
      ),
    );
  }

  @override
  bool get loaded => true;
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  BridgeSession? get bridge => _FakeBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'ws-pdf',
    'workspacePath': '/example-workspace',
  };
  @override
  Map<String, ConversationState> get conversationStates => {'s1': sub.state};

  @override
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    Object? seedCacheEntry,
  }) async => sub;

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? replayCommandId,
  }) async {
    sentTexts.add(text);
    return {'status': 'accepted'};
  }

  @override
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async => {
    'runs': rpcRuns,
  };

  @override
  Future<dynamic> workflowRunEvents(
    String sessionId,
    String runId, {
    int? afterSequence,
    int? limit,
  }) async => const {'events': [], 'hasMore': false};

  @override
  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) async => {
    'artifacts': artifactsByRun[runId] ?? const <Map<String, dynamic>>[],
  };

  @override
  Future<dynamic> workflowRunArtifactRead(
    String sessionId,
    String runId,
    String artifactId, {
    required int version,
    required int offset,
    required int limit,
  }) async {
    return {
      'dataBase64': base64.encode(pdfBytes),
      'mediaType': 'application/pdf',
      'totalBytes': pdfBytes.length,
      'nextOffset': -1,
    };
  }

  void pushRunsSnapshot(int revision, List<Map<String, dynamic>> runs) {
    final nextSeq = sub.state.seq + 1;
    sub.state.applyFrame(
      {
        'fromSeq': sub.state.seq,
        'toSeq': nextSeq,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'state.updated',
              'patch': {
                'workflowRuns': {'revision': revision, 'runs': runs},
              },
            },
          ],
        },
      },
      onGap: () {},
    );
  }
}

Widget _host(
  AppState app,
  Widget home, {
  double? textScale,
}) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    builder: textScale == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
    home: home,
  ),
);

Future<void> _pumpFrames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. PDF 识别与分块读取纯逻辑', () {
    test('artifactLooksPdfByExtension 大小写不敏感与非 PDF 排除', () {
      expect(artifactLooksPdfByExtension('report.pdf'), isTrue);
      expect(artifactLooksPdfByExtension('REPORT.PDF'), isTrue);
      expect(artifactLooksPdfByExtension('.png'), isFalse);
      expect(artifactLooksPdfByExtension('chart.png'), isFalse);
      expect(artifactLooksPdfByExtension('report'), isFalse);
    });

    test('sniffPdfMagic 标准头与前导空白/BOM 命中，PNG/文本排除', () {
      expect(sniffPdfMagic(utf8.encode('%PDF-1.7\n')), isTrue);
      expect(
        sniffPdfMagic([
          0xEF, 0xBB, 0xBF, // UTF-8 BOM
          0x20, 0x0A, 0x0D, // 前导空白
          ...utf8.encode('%PDF-1.4'),
        ]),
        isTrue,
      );
      expect(
        sniffPdfMagic([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        isFalse,
      );
      expect(sniffPdfMagic(utf8.encode('<html><body>hello</body></html>')), isFalse);
      expect(sniffPdfMagic(utf8.encode('notes: magic header is %PDF-1.7')), isFalse);
      expect(sniffPdfMagic(const []), isFalse);
      expect(sniffPdfMagic([0x25, 0x50, 0x44]), isFalse);
    });

    Future<ArtifactBlocks> runBlocks(
      String name,
      List<int> full, {
      int chunk = 512 * 1024,
    }) {
      return readArtifactBlocks(
        name: name,
        read: ({required int offset, required int blockLimit}) async {
          final end = (offset + chunk).clamp(0, full.length);
          return {
            'dataBase64': base64.encode(full.sublist(offset, end)),
            'nextOffset': end < full.length ? end : null,
          };
        },
      );
    }

    test('readArtifactBlocks：无扩展名魔数 PDF 放宽到 32 块不截断', () async {
      final header = utf8.encode('%PDF-1.7\n');
      final body = List<int>.filled(10 * 512 * 1024 - header.length, 0x41);
      final pdf = <int>[...header, ...body]; // 5 MiB（10 块 > 文本 8 块上限）
      final r = await runBlocks('unnamed-doc', pdf);
      expect(r.isPdf, isTrue);
      expect(r.isImage, isFalse);
      expect(r.truncated, isFalse);
      expect(r.oversized, isFalse);
      expect(r.bytes.length, pdf.length);
    });

    test('readArtifactBlocks：超过 16 MiB 且仍有下一块时 oversized == true', () async {
      final header = utf8.encode('%PDF-1.7\n');
      final pdf = <int>[
        ...header,
        ...List<int>.filled(17 * 1024 * 1024, 0x42),
      ];
      final r = await runBlocks('huge.pdf', pdf);
      expect(r.isPdf, isTrue);
      expect(r.oversized, isTrue);
      expect(r.truncated, isFalse);
    });

    test('readArtifactBlocks：恰好 16 MiB 完整 PDF 不误报 oversized', () async {
      final header = utf8.encode('%PDF-1.7\n');
      final pdf = <int>[
        ...header,
        ...List<int>.filled(16 * 1024 * 1024 - header.length, 0x43),
      ];
      final r = await runBlocks('exact16m.pdf', pdf);
      expect(r.isPdf, isTrue);
      expect(r.oversized, isFalse);
      expect(r.truncated, isFalse);
      expect(r.bytes.length, 16 * 1024 * 1024);
    });

    test('readArtifactBlocks：小分块（256 KiB）读取 10 MiB PDF 不静默截断', () async {
      final header = utf8.encode('%PDF-1.7\n');
      final pdf = <int>[
        ...header,
        ...List<int>.filled(10 * 1024 * 1024 - header.length, 0x44),
      ];
      final r = await runBlocks('small-chunks.pdf', pdf, chunk: 256 * 1024);
      expect(r.isPdf, isTrue);
      expect(r.oversized, isFalse);
      expect(r.truncated, isFalse);
      expect(r.bytes.length, 10 * 1024 * 1024);
    });
  });

  group('2. ArtifactPdfPage 完整组件旅程', () {
    late _MemShareDisk memDisk;

    setUp(() {
      memDisk = _MemShareDisk();
      shareDisk = memDisk;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => r'C:\zp-test-cache',
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('companion/share'),
        (call) async => true,
      );
    });

    tearDown(() {
      shareDisk = const ArtifactShareDiskPort();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('companion/share'),
        null,
      );
    });

    testWidgets('多页打开、前后翻页及退出释放原生句柄', (tester) async {
      final backend = _FakePdfBackend(pageCount: 3);
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-pdf'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ArtifactPdfPage(
                      title: 'report.pdf',
                      bytes: _samplePdfBytes,
                      backend: backend,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-pdf')));
      await _pumpFrames(tester);

      expect(find.byKey(const ValueKey('artifact-pdf-pager')), findsOneWidget);
      expect(find.byKey(const ValueKey('artifact-pdf-nav')), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('artifact-pdf-next')));
      await _pumpFrames(tester);
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('artifact-pdf-prev')));
      await _pumpFrames(tester);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.pageBack();
      await _pumpFrames(tester);
      expect(backend.closedHandles, ['pdf-handle-1']);
    });

    testWidgets('单页 PDF 不显示翻页栏', (tester) async {
      final backend = _FakePdfBackend(pageCount: 1);
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'single.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.byKey(const ValueKey('artifact-pdf-pager')), findsOneWidget);
      expect(find.byKey(const ValueKey('artifact-pdf-nav')), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('单页渲染失败提示与点击重试恢复', (tester) async {
      final backend = _FakePdfBackend(pageCount: 2);
      backend.pageScripts[0] = [StateError('render boom'), _png1x1];
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'retry.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('第 1 页渲染失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-pdf-page-retry-0')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('artifact-pdf-page-retry-0')));
      await _pumpFrames(tester);

      expect(find.text('第 1 页渲染失败'), findsNothing);
      expect(
        find.byKey(const ValueKey('artifact-pdf-page-retry-0')),
        findsNothing,
      );
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('加密 PDF 降级提示与分享按钮', (tester) async {
      final backend = _FakePdfBackend(
        openError: const PdfPreviewException(
          PdfPreviewErrorKind.encrypted,
          'password required',
        ),
      );
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'secret.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('无法预览加密 PDF'), findsOneWidget);
      expect(
        find.text('该 PDF 已加密，暂不支持应用内预览，可点右上角分享打开'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artifact-pdf-error-share')),
        findsOneWidget,
      );
    });

    testWidgets('损坏/异常 PDF 降级提示与分享按钮', (tester) async {
      final backend = _FakePdfBackend(
        openError: const PdfPreviewException(
          PdfPreviewErrorKind.invalid,
          'corrupt stream',
        ),
      );
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'broken.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('无法预览 PDF'), findsOneWidget);
      expect(
        find.text('PDF 预览失败，可点右上角分享保存到手机打开'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artifact-pdf-error-share')),
        findsOneWidget,
      );
    });

    testWidgets('英文 + 320dp + 1.3x 字体缩放无缺失翻译与溢出异常', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      L10n.setTestLocale('en-US');
      L10n.collectMissing = true;
      addTearDown(L10n.resetForTest);

      final app = _CollectApp();

      // 1) 正常多页态
      final multiBackend = _FakePdfBackend(pageCount: 3);
      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-en-multi'),
            title: 'report.pdf',
            bytes: _samplePdfBytes,
            backend: multiBackend,
          ),
          textScale: 1.3,
        ),
      );
      await _pumpFrames(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 2) 单页失败态
      final failBackend = _FakePdfBackend(pageCount: 1);
      failBackend.pageScripts[0] = [StateError('fail page 1')];
      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-en-fail'),
            title: 'fail.pdf',
            bytes: _samplePdfBytes,
            backend: failBackend,
          ),
          textScale: 1.3,
        ),
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('artifact-pdf-page-retry-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // 3) 加密错误态
      final encBackend = _FakePdfBackend(
        openError: const PdfPreviewException(
          PdfPreviewErrorKind.encrypted,
          'locked',
        ),
      );
      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-en-enc'),
            title: 'locked.pdf',
            bytes: _samplePdfBytes,
            backend: encBackend,
          ),
          textScale: 1.3,
        ),
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('artifact-pdf-error-share')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      expect(L10n.missingTranslations, isEmpty);
    });

    testWidgets('大文档 40 页懒渲染与连续翻页无异常（volume）', (tester) async {
      final backend = _FakePdfBackend(pageCount: 40);
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'manual-40p.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.byKey(const ValueKey('artifact-pdf-pager')), findsOneWidget);
      expect(find.text('1 / 40'), findsOneWidget);
      // 首屏只按需渲染当前页（最多含邻页预热），不得一次性光栅化全部 40 页。
      expect(backend.renderedPages.length, lessThanOrEqualTo(3));

      for (var i = 0; i < 7; i++) {
        await tester.tap(find.byKey(const ValueKey('artifact-pdf-next')));
        await _pumpFrames(tester, 8);
      }
      expect(find.text('8 / 40'), findsOneWidget);
      expect(backend.renderedPages.length, lessThanOrEqualTo(12));
      final page0BeforeRevisit = backend.renderCallsFor(0);
      expect(page0BeforeRevisit, 1);

      // ⑰ LRU 驱逐护栏：滑到第 8 页时第 1 页已超 5 页 LRU 上限被驱逐，
      // 回访第 1 页必须重新调用原生 renderPage（不再命中旧缓存）。
      for (var i = 0; i < 7; i++) {
        await tester.tap(find.byKey(const ValueKey('artifact-pdf-prev')));
        await _pumpFrames(tester, 8);
      }
      expect(find.text('1 / 40'), findsOneWidget);
      expect(backend.renderCallsFor(0), greaterThan(page0BeforeRevisit));
      expect(tester.takeException(), isNull);
    });

    testWidgets('M4 PDF 页使用有界 ResizeImage 且退出页面主动 evict 解码位图', (
      tester,
    ) async {
      final backend = _FakePdfBackend(pageCount: 2);
      final app = _CollectApp();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await tester.pumpWidget(
        _host(
          app,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-pdf-cache'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ArtifactPdfPage(
                      title: 'cache.pdf',
                      bytes: _samplePdfBytes,
                      backend: backend,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-pdf-cache')));
      await _pumpFrames(tester);

      final image = tester.widget<Image>(find.byType(Image).first);
      expect(image.image, isA<ResizeImage>());
      final resized = image.image as ResizeImage;
      expect(resized.width, inInclusiveRange(360, 2048));
      final cacheKey = await resized.obtainKey(ImageConfiguration.empty);
      expect(PaintingBinding.instance.imageCache.containsKey(cacheKey), isTrue);

      await tester.pageBack();
      await _pumpFrames(tester);
      expect(
        PaintingBinding.instance.imageCache.containsKey(cacheKey),
        isFalse,
      );
    });

    testWidgets('缩放态锁死 PageView 横向滑动，未放大态恢复翻页且禁用平移', (
      tester,
    ) async {
      final backend = _FakePdfBackend(pageCount: 3);
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'zoom.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      final pagerFinder = find.byKey(const ValueKey('artifact-pdf-pager'));
      final viewerFinder = find.byType(InteractiveViewer);

      // 未放大态：PageView 可滑（physics == null），InteractiveViewer.panEnabled == false。
      expect(tester.widget<PageView>(pagerFinder).physics, isNull);
      final viewer0 = tester.widget<InteractiveViewer>(viewerFinder);
      expect(viewer0.panEnabled, isFalse);
      expect(viewer0.transformationController, isNotNull);

      // 模拟双指放大到 2x：PageView 切为 NeverScrollableScrollPhysics，panEnabled == true。
      viewer0.transformationController!.value =
          Matrix4.diagonal3Values(2.0, 2.0, 1.0);
      await tester.pump();

      expect(
        tester.widget<PageView>(pagerFinder).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      expect(tester.widget<InteractiveViewer>(viewerFinder).panEnabled, isTrue);

      // 放大态横向拖拽不翻页（仍停留在 1 / 3）。
      await tester.drag(pagerFinder, const Offset(-300, 0));
      await _pumpFrames(tester, 4);
      expect(find.text('1 / 3'), findsOneWidget);

      // 点下一页切页后重置缩放锁：PageView 恢复可滑、panEnabled == false。
      await tester.tap(find.byKey(const ValueKey('artifact-pdf-next')));
      await _pumpFrames(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      expect(tester.widget<PageView>(pagerFinder).physics, isNull);
      expect(tester.widget<InteractiveViewer>(viewerFinder).panEnabled, isFalse);
    });

    testWidgets('非 .pdf 后缀魔数 PDF 点分享落盘文件名补齐 .pdf', (tester) async {
      final backend = _FakePdfBackend(pageCount: 1);
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-share-ext'),
            title: 'notes.txt',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('artifact-pdf-share')));
      await _pumpFrames(tester);

      expect(memDisk.files.keys, hasLength(1));
      final savedPath = memDisk.files.keys.single;
      expect(savedPath.endsWith('.pdf'), isTrue);
      expect(
        savedPath.endsWith('${Platform.pathSeparator}notes.txt.pdf'),
        isTrue,
      );

      // 空标题兜底 document.pdf；已有 .PDF 后缀不重复追加。
      memDisk.files.clear();
      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-share-empty'),
            title: '   ',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-pdf-share')));
      await _pumpFrames(tester);
      expect(
        memDisk.files.keys.single
            .endsWith('${Platform.pathSeparator}document.pdf'),
        isTrue,
      );
    });

    testWidgets('横屏矮屏 640x300 + 1.3x 字体缩放下文档加密与单页失败态零溢出', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = _CollectApp();

      // 1) 文档级加密错误态
      final encBackend = _FakePdfBackend(
        openError: const PdfPreviewException(
          PdfPreviewErrorKind.encrypted,
          'locked',
        ),
      );
      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-landscape-enc'),
            title: 'locked.pdf',
            bytes: _samplePdfBytes,
            backend: encBackend,
          ),
          textScale: 1.3,
        ),
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('artifact-pdf-error-share')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // 2) 单页渲染失败态（多页含底部翻页栏，高度更极限）
      final failBackend = _FakePdfBackend(pageCount: 2);
      failBackend.pageScripts[0] = [StateError('render fail')];
      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            key: const ValueKey('pdf-landscape-page-fail'),
            title: 'fail.pdf',
            bytes: _samplePdfBytes,
            backend: failBackend,
          ),
          textScale: 1.3,
        ),
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('artifact-pdf-page-retry-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('并发 renderPage 限制最多 2 页在飞，快翻时当前页优先', (tester) async {
      final gates = <int, Completer<Uint8List>>{};
      final requestOrder = <int>[];
      final backend = _FakePdfBackend(pageCount: 5);
      backend.onRenderAsync = (pageIndex) {
        requestOrder.add(pageIndex);
        final completer = Completer<Uint8List>();
        gates[pageIndex] = completer;
        return completer.future;
      };
      final app = _CollectApp();

      await tester.pumpWidget(
        _host(
          app,
          ArtifactPdfPage(
            title: 'throttle.pdf',
            bytes: _samplePdfBytes,
            backend: backend,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // 第 0 页打开：最多发出 0、1 两页在飞。
      expect(backend.maxInFlightRenders, lessThanOrEqualTo(2));
      expect(requestOrder, [0, 1]);

      // 连翻两页到第 2 页（索引 2）：等待动画越过切页线但 0、1 仍在飞，第 2 页入队头等待。
      await tester.tap(find.byKey(const ValueKey('artifact-pdf-next')));
      await _pumpFrames(tester, 5);
      await tester.tap(find.byKey(const ValueKey('artifact-pdf-next')));
      await _pumpFrames(tester, 5);
      expect(find.text('3 / 5'), findsOneWidget);
      expect(backend.maxInFlightRenders, lessThanOrEqualTo(2));

      // 放行 0、1 页后，当前页 2 优先被发出（先于邻页 3），且全过程同时在飞不超过 2。
      gates.remove(0)?.complete(_png1x1);
      gates.remove(1)?.complete(_png1x1);
      await _pumpFrames(tester, 4);
      expect(backend.maxInFlightRenders, lessThanOrEqualTo(2));
      final idx2 = requestOrder.indexOf(2);
      final idx3 = requestOrder.indexOf(3);
      expect(idx2, greaterThanOrEqualTo(0));
      if (idx3 >= 0) {
        expect(idx2, lessThan(idx3));
      }

      for (final c in gates.values) {
        if (!c.isCompleted) c.complete(_png1x1);
      }
      await _pumpFrames(tester, 4);
    });

    test('MethodChannelPdfPreviewBackend 并发 open 仅清扫旧残留且不误删在途文件', () async {
      final tempRoot = Directory.systemTemp.createTempSync('pdf_sweep_race_');
      final previewDir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}pdf_preview',
      )..createSync(recursive: true);
      final staleFile = File(
        '${previewDir.path}${Platform.pathSeparator}doc_stale_0.pdf',
      )..writeAsBytesSync(_samplePdfBytes, flush: true);

      final backend = MethodChannelPdfPreviewBackend.instance;
      backend.resetForTest();
      backend.debugTempDirProvider = () async => tempRoot;

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final openStarted = <String>[];
      final openGates = <Completer<Map<String, Object>>>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('companion/pdf'),
        (call) async {
          if (call.method == 'open') {
            final path = (call.arguments as Map)['path'] as String;
            openStarted.add(path);
            // 在途窗口再主动触发一次清扫，验证 _pendingPaths 保护生效。
            await backend.sweepStaleTempFilesForTest(previewDir);
            final gate = Completer<Map<String, Object>>();
            openGates.add(gate);
            return gate.future;
          }
          if (call.method == 'close') {
            return true;
          }
          return null;
        },
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(
          const MethodChannel('companion/pdf'),
          null,
        );
        backend.resetForTest();
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      final f1 = backend.open(_samplePdfBytes);
      final f2 = backend.open(_samplePdfBytes);

      for (var i = 0; i < 50 && openGates.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(openGates.length, 2);
      expect(staleFile.existsSync(), isFalse, reason: '旧残留临时文件必须被清扫');
      for (final p in openStarted) {
        expect(
          File(p).existsSync(),
          isTrue,
          reason: '并发在途新文件绝不可被清扫误删: $p',
        );
      }

      openGates[0].complete({'handle': 'h-1', 'pageCount': 2});
      openGates[1].complete({'handle': 'h-2', 'pageCount': 3});
      final docs = await Future.wait([f1, f2]);
      expect(docs.map((d) => d.handle).toSet(), {'h-1', 'h-2'});
      expect(backend.pendingCountForTest, 0);

      // 再次触发清扫：已打开句柄对应文件仍受 _tempFiles 保护不被删除。
      await backend.sweepStaleTempFilesForTest(previewDir);
      for (final p in openStarted) {
        expect(File(p).existsSync(), isTrue);
      }

      await backend.close(docs[0].handle);
      await backend.close(docs[1].handle);
      for (final p in openStarted) {
        expect(File(p).existsSync(), isFalse);
      }
    });
  });

  group('3. WorkflowRunDetailPage 路由门控', () {
    testWidgets('Android 默认走 ArtifactPdfPage', (tester) async {
      final backend = _FakePdfBackend(pageCount: 2);
      debugPdfPreviewBackend = backend;
      try {
        final app = _CollectApp();
        await tester.pumpWidget(
          _host(
            app,
            const WorkflowRunDetailPage(
              sessionId: 's1',
              runId: 'run-1',
              title: '工作流运行',
            ),
          ),
        );
        await _pumpFrames(tester);

        await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-pdf')));
        await _pumpFrames(tester);

        expect(find.byType(ArtifactPdfPage), findsOneWidget);
        expect(find.byType(BinaryArtifactPage), findsNothing);
        expect(find.text('1 / 2'), findsOneWidget);
      } finally {
        debugPdfPreviewBackend = null;
      }
    });

    testWidgets('iOS 回落 BinaryArtifactPage（不推 ArtifactPdfPage）', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        // 纯 ASCII 合法 UTF-8 PDF（无 NUL 字节）也必须走 BinaryArtifactPage，
        // 不能误落入文本源码页。
        final asciiPdf = Uint8List.fromList(
          utf8.encode('%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF\n'),
        );
        final app = _CollectApp(pdfBytes: asciiPdf);
        await tester.pumpWidget(
          _host(
            app,
            const WorkflowRunDetailPage(
              sessionId: 's1',
              runId: 'run-1',
              title: '工作流运行',
            ),
          ),
        );
        await _pumpFrames(tester);

        await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-pdf')));
        await _pumpFrames(tester);

        expect(find.byType(BinaryArtifactPage), findsOneWidget);
        expect(find.byType(ArtifactPdfPage), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('4. ConversationPage「收集产物」完成直达提示条旅程', () {
    Future<void> sendCollectFromHub(
      WidgetTester tester,
      _CollectApp app,
    ) async {
      await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: '产物收集测试')),
      );
      await _pumpFrames(tester, 14);

      await tester.tap(find.byKey(const ValueKey('downloads-entry')));
      await _pumpFrames(tester, 10);
      expect(find.byType(WorkflowRunsPage), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hub-collect-button')));
      await _pumpFrames(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-send')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('collect-artifacts-send')));
      await _pumpFrames(tester, 10);
      expect(app.sentTexts, isNotEmpty);

      await tester.pageBack();
      await _pumpFrames(tester, 10);
      expect(find.byType(WorkflowRunsPage), findsNothing);
    }

    testWidgets('旧 run 与空产物 run 不触发；新 run 就绪弹出直达条并点击查看直入详情', (
      tester,
    ) async {
      final app = _CollectApp();
      await sendCollectFromHub(tester, app);

      // 1) 已存在的旧 run-old 不触发直达条
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );

      // 2) 新 run 完成但 artifacts 为显式空列表 [] 不触发直达条
      //    （严格按官方 workflowRunSchema，快照投影不含 label 字段）
      app.pushRunsSnapshot(2, const [
        {
          'runId': 'run-old',
          'toolCallId': 'tc-old',
          'status': 'completed',
          'lastEventSequence': 10,
          'artifacts': [
            {'id': 'a-old', 'kind': 'text'},
          ],
        },
        {
          'runId': 'run-empty',
          'toolCallId': 'tc-empty',
          'status': 'completed',
          'lastEventSequence': 20,
          'artifacts': <Map<String, dynamic>>[],
        },
      ]);
      await _pumpFrames(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );

      // 3) 新 run 完成且带 2 个产物 → 弹出直达条
      app.pushRunsSnapshot(3, const [
        {
          'runId': 'run-old',
          'toolCallId': 'tc-old',
          'status': 'completed',
          'lastEventSequence': 10,
          'artifacts': [
            {'id': 'a-old', 'kind': 'text'},
          ],
        },
        {
          'runId': 'run-new',
          'toolCallId': 'tc-new',
          'status': 'completed',
          'lastEventSequence': 42,
          'artifacts': [
            {'id': 'art-new-1', 'kind': 'file'},
            {'id': 'art-new-2', 'kind': 'text'},
          ],
        },
      ]);
      await _pumpFrames(tester, 8);

      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsOneWidget,
      );
      expect(find.text('产物已就绪（2 个）'), findsOneWidget);

      // 4) 点「查看」→ 横幅消失并直入 WorkflowRunDetailPage(run-new)
      await tester.tap(
        find.byKey(const ValueKey('collect-artifacts-ready-open')),
      );
      await _pumpFrames(tester, 12);

      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );
      final detailFinder = find.byType(WorkflowRunDetailPage);
      expect(detailFinder, findsOneWidget);
      final detail = tester.widget<WorkflowRunDetailPage>(detailFinder);
      expect(detail.runId, 'run-new');
      expect(detail.title, isNot('run-new'), reason: 'M1：不得退化为裸 runId');
    });

    testWidgets('点关闭钮隐藏直达提示条不跳转', (tester) async {
      final app = _CollectApp();
      await sendCollectFromHub(tester, app);

      app.pushRunsSnapshot(2, const [
        {
          'runId': 'run-old',
          'toolCallId': 'tc-old',
          'status': 'completed',
          'lastEventSequence': 10,
          'artifacts': [
            {'id': 'a-old', 'kind': 'text'},
          ],
        },
        {
          'runId': 'run-new',
          'toolCallId': 'tc-new',
          'status': 'completed',
          'lastEventSequence': 42,
          'artifacts': [
            {'id': 'art-new-1', 'kind': 'file'},
            {'id': 'art-new-2', 'kind': 'text'},
          ],
        },
      ]);
      await _pumpFrames(tester, 8);

      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('collect-artifacts-ready-dismiss')),
      );
      await _pumpFrames(tester, 6);

      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );
      expect(find.byType(WorkflowRunDetailPage), findsNothing);
    });
  });
}
