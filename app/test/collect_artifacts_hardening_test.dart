import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/state/draft_store.dart';
import 'package:zpocket/state/send_queue_store.dart';
import 'package:zpocket/transport/channel_client.dart';
import 'package:zpocket/transport/companion_client.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/transport/rpc_frame_transport.dart';
import 'package:zpocket/transport/z_transport.dart';
import 'package:zpocket/ui/conversation_page.dart';
import 'package:zpocket/ui/workflow_runs_page.dart';

class _MemoryDraftStore extends DraftStore {
  _MemoryDraftStore([Map<String, ComposerDraft>? initial])
    : _data = {...?initial},
      super(Directory.systemTemp);

  final Map<String, ComposerDraft> _data;

  @override
  Future<ComposerDraft?> read(DraftIdentity identity) async =>
      _data[identity.key];

  @override
  Future<void> save(ComposerDraft draft) async {
    final current = _data[draft.identity.key];
    if (current != null && draft.revision < current.revision) return;
    if (draft.hasRecoverableContent) {
      _data[draft.identity.key] = draft;
    } else {
      _data.remove(draft.identity.key);
    }
  }

  @override
  Future<void> delete(DraftIdentity identity, {int? expectedRevision}) async {
    if (expectedRevision != null &&
        _data[identity.key]?.revision != expectedRevision) {
      return;
    }
    _data.remove(identity.key);
  }

  @override
  Future<void> removeDevice(String deviceSid) async {
    _data.removeWhere((_, draft) => draft.identity.deviceSid == deviceSid);
  }

  @override
  Future<void> removeSession(String deviceSid, String sessionId) async {
    _data.removeWhere(
      (_, draft) =>
          draft.identity.deviceSid == deviceSid &&
          draft.identity.scopeId == 'session:$sessionId',
    );
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

class _ProbeSendQueue extends SendQueueStore {
  _ProbeSendQueue()
    : super(
        File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'collect-hardening-queue-${DateTime.now().microsecondsSinceEpoch}.json',
        ),
      );

  final List<SendQueueEntry> addedEntries = [];

  @override
  Future<List<SendQueueEntry>> entries(SendQueueBucket bucket) async =>
      List<SendQueueEntry>.unmodifiable(addedEntries);

  @override
  Future<void> add(SendQueueBucket bucket, SendQueueEntry entry) async {
    addedEntries.add(entry);
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
  String? get workspaceKey => 'workspace-collect';
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
  bool liveFrames = true;
  @override
  bool get hasLiveFrames => liveFrames;
  @override
  String? get subscriptionId => 'sub-collect-hardening';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _HardeningCollectApp extends AppState {
  final _FakeSub sub = _FakeSub('s1');
  final List<({String text, List<Map<String, dynamic>>? attachments})>
  sendCalls = [];
  BridgeSession? currentBridge = _FakeBridge();
  LinkPhase currentPhase = LinkPhase.online;
  dynamic sendResult = const {'status': 'accepted'};
  Object? sendError;
  Completer<dynamic>? sendGate;

  _HardeningCollectApp(
    DraftStore draftStore, {
    SendQueueStore? queue,
    List<Map<String, dynamic>>? initialRuns,
  }) : super(draftStore: draftStore) {
    uiPrefs.debugMarkLoadedForTest();
    sendQueue = queue;
    activeProfile = AccountV2Profile(
      deviceSid: 'device-a',
      accountId: 'account-a',
      label: '测试电脑',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
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
          'title': '收集产物加固测试',
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
  LinkPhase get phase => currentPhase;

  @override
  BridgeSession? get bridge => currentBridge;

  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'workspace-collect',
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
  Future<({List<int> bytes, String? mediaType})> attachmentRead(
    String sessionId,
    String ref, {
    Map<String, dynamic>? target,
    int? attachmentIndex,
  }) async => (bytes: const <int>[1, 2, 3, 4], mediaType: 'text/plain');

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
    sendCalls.add((text: text, attachments: attachments));
    if (sendGate != null) return sendGate!.future;
    if (sendError != null) throw sendError!;
    return sendResult;
  }

  @override
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async => const {
    'runs': [],
  };

  @override
  Future<dynamic> workflowRunEvents(
    String sessionId,
    String runId, {
    int? afterSequence,
    int? limit,
  }) async => const {'events': [], 'hasMore': false};

  @override
  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) async =>
      const {'artifacts': []};

  void pushSnapshot({
    required int seqRevision,
    String conversationPhase = 'completedSuccess',
    required List<Map<String, dynamic>> runs,
  }) {
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
                'control': {'phase': conversationPhase},
                'workflowRuns': {'revision': seqRevision, 'runs': runs},
              },
            },
          ],
        },
      },
      onGap: () {},
    );
  }
}

DraftIdentity _sessionDraftId() => DraftIdentity.session(
  deviceSid: 'device-a',
  accountId: 'account-a',
  workspaceKey: 'workspace-collect',
  sessionId: 's1',
);

Widget _host(_HardeningCollectApp app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const ConversationPage(sessionId: 's1', title: '收集产物加固测试'),
  ),
);

Future<void> _pump(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _inputText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('chat-input')))
    .controller!
    .text;

Future<void> _triggerCollectSend(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('downloads-entry')));
  await _pump(tester);
  expect(find.byType(WorkflowRunsPage), findsOneWidget);

  await tester.tap(find.byKey(const ValueKey('hub-collect-button')));
  await _pump(tester, 8);
  expect(find.byKey(const ValueKey('collect-artifacts-send')), findsOneWidget);

  await tester.tap(find.byKey(const ValueKey('collect-artifacts-send')));
  await _pump(tester);
}

void main() {
  tearDown(L10n.resetForTest);

  test('kCollectArtifactsPrompt 保留 /workflow 激活前缀与未启用兜底句（1.0.9 验收③）', () {
    // 前缀是官方 onDemand 模式的激活语义（input facade 展开处即激活点），
    // 丢了前缀=未激活会话里四个工作流工具不在列表，收集必失败。
    expect(kCollectArtifactsPrompt.startsWith('/workflow '), isTrue);
    // 灰度关闭的桌面原文照发，末句兜底让 agent 明确回复而不是乱试。
    expect(kCollectArtifactsPrompt, contains('CreateWorkflow'));
    // 官方命令解析形态：/workflow 后必须紧跟参数分隔的指令正文。
    expect(
      RegExp(r'^/\S+\s+\S').hasMatch(kCollectArtifactsPrompt),
      isTrue,
      reason: '命中 builtin-prompt-command 的命令正则才会展开',
    );
  });

  group('收集产物独立发送与草稿/附件/离线隔离', () {
    testWidgets('挂着草稿待发附件（含失效附件）时点收集产物：不带走、不清空、不被拦截', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      await store.save(
        ComposerDraft(
          identity: _sessionDraftId(),
          text: '待发草稿正文',
          attachments: const [
            DraftAttachment(
              fileName: 'valid.txt',
              mime: 'text/plain',
              byteSize: 4,
              reference: {
                'ref': 'ref-valid',
                'fileName': 'valid.txt',
                'mime': 'text/plain',
                'bytes': 4,
              },
            ),
            DraftAttachment(
              fileName: 'broken.png',
              mime: 'image/png',
              byteSize: 12,
              reference: null,
            ),
          ],
          updatedAt: 100,
          revision: 3,
        ),
      );

      final app = _HardeningCollectApp(store);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      expect(_inputText(tester), '待发草稿正文');
      expect(find.textContaining('valid.txt'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pending-attachment-restored-3-1')),
        findsOneWidget,
      );

      await _triggerCollectSend(tester);
      expect(app.sendCalls, hasLength(1));
      expect(app.sendCalls.single.text, kCollectArtifactsPrompt);
      expect(app.sendCalls.single.attachments, isNull);
      expect(find.text('已发送收集指令，产物就绪后会出现在下方'), findsOneWidget);

      await tester.pageBack();
      await _pump(tester);

      expect(_inputText(tester), '待发草稿正文');
      expect(find.textContaining('valid.txt'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pending-attachment-restored-3-1')),
        findsOneWidget,
      );
      final saved = await store.read(_sessionDraftId());
      expect(saved?.text, '待发草稿正文');
      expect(saved?.attachments, hasLength(2));
      expect(saved?.submissionInFlight, isFalse);
    });

    testWidgets('收集指令发送失败或被拒时：绝不回填 kCollectArtifactsPrompt 到输入框或暂存草稿', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      await store.save(
        ComposerDraft(
          identity: _sessionDraftId(),
          text: '用户原有输入',
          attachments: const [],
          updatedAt: 100,
          revision: 2,
        ),
      );
      final app = _HardeningCollectApp(store)
        ..sendResult = const {'status': 'rejected', 'reasonCode': 'busy'};
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      expect(app.sendCalls, hasLength(1));
      expect(find.text('未能发送（会话正忙或发送失败），请稍后再试'), findsOneWidget);
      expect(find.text('已发送收集指令，产物就绪后会出现在下方'), findsNothing);

      await tester.pageBack();
      await _pump(tester);

      expect(_inputText(tester), '用户原有输入');
      expect(_inputText(tester), isNot(contains(kCollectArtifactsPrompt)));
      expect(find.byKey(const ValueKey('restore-unsent')), findsNothing);
      final saved = await store.read(_sessionDraftId());
      expect(saved?.text, '用户原有输入');
      expect(saved?.unsentText, isNull);
      expect(saved?.submissionInFlight, isFalse);
    });

    testWidgets('收集指令遇到丢帧错误（response frame lost）不标记结果未知也不污染草稿', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store)
        ..sendError = StateError('response frame lost');
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      expect(find.text('未能发送（会话正忙或发送失败），请稍后再试'), findsOneWidget);

      await tester.pageBack();
      await _pump(tester);

      expect(_inputText(tester), isEmpty);
      expect(find.byKey(const ValueKey('restore-unsent')), findsNothing);
      final saved = await store.read(_sessionDraftId());
      expect(saved, isNull);
    });

    testWidgets('离线/重连态点收集产物直接拒发返回 false、不写离线队列、不误弹已发送', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final queue = _ProbeSendQueue();
      final app = _HardeningCollectApp(store, queue: queue)
        ..currentPhase = LinkPhase.reconnecting
        ..currentBridge = null;
      addTearDown(app.dispose);

      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      expect(app.sendCalls, isEmpty);
      expect(queue.addedEntries, isEmpty);
      expect(find.text('已发送收集指令，产物就绪后会出现在下方'), findsNothing);
      expect(find.text('未能发送（会话正忙或发送失败），请稍后再试'), findsOneWidget);
    });
  });

  group('收集产物直达条状态机收口', () {
    testWidgets('首轮新 run 失败且另一新 run 仍 running / 重试成功时，直达条仍正常弹出', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      await tester.pageBack();
      await _pump(tester);

      // 首轮新 run-fail 失败，同时新 run-retry 仍 running（或会话回合仍在运行）
      app.pushSnapshot(
        seqRevision: 2,
        conversationPhase: 'running',
        runs: const [
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
            'runId': 'run-fail',
            'toolCallId': 'tc-fail',
            'status': 'errored',
            'lastEventSequence': 20,
          },
          {
            'runId': 'run-retry',
            'toolCallId': 'tc-retry',
            'status': 'running',
            'lastEventSequence': 21,
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );

      // 重试 run 完成且带 2 个产物 → 正常弹出直达条
      app.pushSnapshot(
        seqRevision: 3,
        conversationPhase: 'completedSuccess',
        runs: const [
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
            'runId': 'run-fail',
            'toolCallId': 'tc-fail',
            'status': 'errored',
            'lastEventSequence': 20,
          },
          {
            'runId': 'run-retry',
            'toolCallId': 'tc-retry',
            'status': 'completed',
            'lastEventSequence': 35,
            'artifacts': [
              {'id': 'art-1', 'kind': 'file'},
              {'id': 'art-2', 'kind': 'text'},
            ],
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsOneWidget,
      );
      expect(find.text('产物已就绪（2 个）'), findsOneWidget);
    });

    testWidgets('省略 artifacts 字段（artifacts: null）时不误弹空直达条', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      await tester.pageBack();
      await _pump(tester);

      app.pushSnapshot(
        seqRevision: 2,
        conversationPhase: 'completedSuccess',
        runs: const [
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
            'runId': 'run-null-arts',
            'toolCallId': 'tc-null',
            'status': 'completed',
            'lastEventSequence': 25,
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );
      expect(find.text('收集的产物已就绪'), findsNothing);
    });

    testWidgets('收集发送失败时不残留监听窗口：后续新 run 完成也不误弹直达条', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store)
        ..sendError = StateError('send failed');
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      await tester.pageBack();
      await _pump(tester);

      app.pushSnapshot(
        seqRevision: 2,
        conversationPhase: 'completedSuccess',
        runs: const [
          {
            'runId': 'run-unrelated',
            'toolCallId': 'tc-u',
            'status': 'completed',
            'lastEventSequence': 30,
            'artifacts': [
              {'id': 'art-u', 'kind': 'text'},
            ],
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );
    });

    testWidgets('M1 真实快照无 label：从关联 CreateWorkflow 工具行派生标题，否则兜底「工作流」不露裸 runId', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      await tester.pageBack();
      await _pump(tester);

      // 追加真实形态 CreateWorkflow 工具行 + 无 label 的官方 workflowRunSchema 投影
      final nextSeq = app.sub.state.seq + 1;
      app.sub.state.applyFrame(
        {
          'fromSeq': app.sub.state.seq,
          'toSeq': nextSeq,
          'payload': {
            'kind': 'deltas',
            'deltas': [
              {
                'op': 'row.appended',
                'row': {
                  'rowId': 3,
                  'kind': 'toolCall',
                  'toolName': 'CreateWorkflow',
                  'toolCallId': 'tc-collect-real',
                  'input': {'name': '归档月报产物'},
                },
              },
              {
                'op': 'state.updated',
                'patch': {
                  'control': {'phase': 'completedSuccess'},
                  'workflowRuns': {
                    'revision': 2,
                    'runs': const [
                      {
                        'runId': 'dwfrun-abc123',
                        'toolCallId': 'tc-collect-real',
                        'status': 'completed',
                        'lastEventSequence': 12,
                        'artifacts': [
                          {'id': 'art-1', 'kind': 'file', 'title': 'monthly.pdf'},
                          {'id': 'art-2', 'kind': 'text', 'title': 'notes.txt'},
                        ],
                      },
                    ],
                  },
                },
              },
            ],
          },
        },
        onGap: () {},
      );
      await _pump(tester, 8);

      await tester.tap(
        find.byKey(const ValueKey('collect-artifacts-ready-open')),
      );
      await _pump(tester, 10);

      final detail = tester.widget<WorkflowRunDetailPage>(
        find.byType(WorkflowRunDetailPage),
      );
      expect(detail.runId, 'dwfrun-abc123');
      expect(detail.title, '归档月报产物');
    });

    testWidgets('M2 缓存种子态发送收集：首个活快照到达吸收桌面旧 run 不误弹，真正新收集 run 完成才弹条', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store);
      app.sub.liveFrames = false; // 模拟冷启动缓存种子态（尚未收到活快照）
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      await tester.pageBack();
      await _pump(tester);

      // 首个活快照到达：携带种子水位之后桌面端早已跑完的旧 run（无新 CreateWorkflow 行）
      app.sub.liveFrames = true;
      app.pushSnapshot(
        seqRevision: 2,
        conversationPhase: 'running',
        runs: const [
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
            'runId': 'run-desktop-stale',
            'toolCallId': 'tc-desktop-stale',
            'status': 'completed',
            'lastEventSequence': 18,
            'artifacts': [
              {'id': 'a-stale', 'kind': 'file', 'title': 'stale.pdf'},
            ],
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
        reason: '首个活快照中的既有桌面旧 run 必须被吸收进基线，不得误弹',
      );

      // 随后真正的收集 run 完成 → 正常弹出直达条
      app.pushSnapshot(
        seqRevision: 3,
        conversationPhase: 'completedSuccess',
        runs: const [
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
            'runId': 'run-desktop-stale',
            'toolCallId': 'tc-desktop-stale',
            'status': 'completed',
            'lastEventSequence': 18,
            'artifacts': [
              {'id': 'a-stale', 'kind': 'file', 'title': 'stale.pdf'},
            ],
          },
          {
            'runId': 'run-collect-ok',
            'toolCallId': 'tc-collect-ok',
            'status': 'completed',
            'lastEventSequence': 22,
            'artifacts': [
              {'id': 'a-ok', 'kind': 'file', 'title': 'report.pdf'},
            ],
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsOneWidget,
      );
      expect(find.text('产物已就绪（1 个）'), findsOneWidget);
    });

    testWidgets('M2 回合纯文本回复未建工作流时自动关闭监听，后续无关 run 不误弹直达条', (
      tester,
    ) async {
      final store = _MemoryDraftStore();
      final app = _HardeningCollectApp(store);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(app));
      await _pump(tester, 14);

      await _triggerCollectSend(tester);
      await tester.pageBack();
      await _pump(tester);

      // 回合进入运行再正常结束，期间未建任何新工作流
      app.pushSnapshot(
        seqRevision: 2,
        conversationPhase: 'running',
        runs: const [
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
      );
      await _pump(tester, 4);
      app.pushSnapshot(
        seqRevision: 3,
        conversationPhase: 'completedSuccess',
        runs: const [
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
      );
      await _pump(tester, 4);

      // 之后同一会话跑出其他无关工作流，不得突弹收集直达条
      app.pushSnapshot(
        seqRevision: 4,
        conversationPhase: 'completedSuccess',
        runs: const [
          {
            'runId': 'run-later-unrelated',
            'toolCallId': 'tc-later',
            'status': 'completed',
            'lastEventSequence': 50,
            'artifacts': [
              {'id': 'a-later', 'kind': 'file', 'title': 'later.pdf'},
            ],
          },
        ],
      );
      await _pump(tester, 8);
      expect(
        find.byKey(const ValueKey('collect-artifacts-ready-banner')),
        findsNothing,
      );
    });
  });
}
