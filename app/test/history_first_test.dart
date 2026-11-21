// history-first-1（2026-11-20）：clientHello 能力协商+冷会话历史先行的
// 协议与 UI 钉子——①单向声明纪律（host 明示才带 capabilities，未明示
// 不带键=strict 对象防误伤老 Host）②subscribe 顶层 retryInitialization
// 一次性（ACK 清除，桥恢复自动重订阅不再携带）③runtimeInitialization
// 三态消费（快照/patch/缺席=不门控）④applySeed 保真种子值（水位不变量）失败重试
// 仅 failed 态触发UI：initializing 发送键禁用不发 RPC、failed 失败条+
// 重试、ready 恢复可发。红=旧实现无能力声明/无重试字段/无门控。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/transport/channel_client.dart';
import 'package:zpocket/transport/companion_client.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/transport/rpc_frame_transport.dart';
import 'package:zpocket/ui/conversation_page.dart';
import 'package:zpocket/ui/conversation_composer.dart' show InputBar;
import 'package:zpocket/state/cache_policy.dart' show SessionCacheEntry;

class _HfChannel extends ChannelClient {
  _HfChannel({this.historyFirst = true, this.overrideCaps})
    : super(sendBody: (_) {});
  final bool historyFirst;

  /// 非空时 hello 的 capabilities 用它（负例注入：false/'true' 等脏值）。
  final Map<String, dynamic>? overrideCaps;

  /// 置位后下一次 subscribeConversationV4 抛错一次（失败自动重试链用例）。
  bool failNextSubscribe = false;
  final calls = <(String, Map<String, dynamic>)>[];
  final frameListeners = <String, void Function(dynamic event)>{};
  int _subAcks = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((
      method,
      args.isEmpty
          ? const <String, dynamic>{}
          : (args.first as Map).cast<String, dynamic>(),
    ));
    switch (method) {
      case 'helloConversationV4':
        return {
          'connectionId': 'conn-hf',
          if (overrideCaps != null)
            'capabilities': overrideCaps
          else if (historyFirst)
            'capabilities': {'historyFirst': true},
        };
      case 'initializeConversationV4':
        return {'ok': true};
      case 'subscribeConversationV4':
        if (failNextSubscribe) {
          failNextSubscribe = false;
          throw StateError('subscribe rpc dead');
        }
        _subAcks++;
        return {
          'ack': {
            'subscriptionId': 'sub-$_subAcks',
            'mode': 'snapshot',
            'logEpoch': 'e1',
          },
        };
    }
    return <String, dynamic>{};
  }

  @override
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    frameListeners[event] = onEvent;
    return () {
      frameListeners.remove(event);
    };
  }

  void emitConversationFrame(String sessionId, Map<String, dynamic> inner) {
    frameListeners['onDynamicConversationFrame']?.call({
      'topic': 'conversation/$sessionId',
      'kind': 'complete',
      // 生产帧带 subscriptionId 且受理侧校验——自动补当前代 id。
      'frame': {...inner, 'subscriptionId': 'sub-$_subAcks'},
    });
  }

  List<(String, Map<String, dynamic>)> callsOf(String m) =>
      calls.where((c) => c.$1 == m).toList();
}

class _HfBridge implements BridgeSession {
  _HfBridge(this.channel);
  final _HfChannel channel;
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
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-hf';
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

ConversationTransport _transport(_HfBridge bridge) => ConversationTransport(
  session: bridge,
  scope: const {'workspacePath': r'C:\demo'},
);

Map<String, dynamic> _snapFrame(
  Map<String, dynamic> snapshot, {
  int toSeq = 1,
}) => {
  'toSeq': toSeq,
  'payload': {'kind': 'snapshot', 'snapshot': snapshot},
};

Map<String, dynamic> _deltaFrame(
  int fromSeq,
  int toSeq,
  List<Map<String, dynamic>> deltas,
) => {
  'fromSeq': fromSeq,
  'toSeq': toSeq,
  'payload': {'kind': 'deltas', 'deltas': deltas},
};

Map<String, dynamic> _runtimeInit(
  String status,
  String attemptId, {
  String? reasonCode,
  String? message,
}) => {
  'status': status,
  'attemptId': attemptId,
  if (reasonCode != null) 'reasonCode': reasonCode,
  if (message != null) 'message': message,
};

Map<String, dynamic> _sessionSnap({Map<String, dynamic>? runtimeInit}) => {
  'sessionId': 's1',
  'logEpoch': 'e1',
  'seq': 1,
  'revision': 0,
  'control': const {'phase': 'idle'},
  if (runtimeInit != null) 'runtimeInitialization': runtimeInit,
  'rows': {
    'window': const [
      {'rowId': 1, 'kind': 'userInput', 'text': '早', 'createdAt': 1},
    ],
    'totalCount': 1,
    'firstRowId': 1,
  },
};

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('握手能力协商：host 明示 true 才声明；未明示不带 capabilities 键', () async {
    final bridgeT = _HfBridge(_HfChannel(historyFirst: true));
    final convT = _transport(bridgeT);
    await convT.handshake();
    expect(
      convT.hostCapabilities?['historyFirst'],
      true,
      reason: 'hello 响应的 capabilities 已存档',
    );
    final init = bridgeT.channel.callsOf('initializeConversationV4').single.$2;
    expect(init['capabilities'], {'historyFirst': true}, reason: 'host 明示才回声明');

    final bridgeF = _HfBridge(_HfChannel(historyFirst: false));
    final convF = _transport(bridgeF);
    await convF.handshake();
    final init2 = bridgeF.channel.callsOf('initializeConversationV4').single.$2;
    expect(
      init2.containsKey('capabilities'),
      isFalse,
      reason: '未明示不带键——strict 对象禁未知键，老 Host 收到=整条握手失败',
    );

    // 显式 false 与非 bool 值同样不声明（=== true 判定，审查 T5 负例）。
    for (final caps in [
      {'historyFirst': false},
      {'historyFirst': 'true'},
    ]) {
      final b = _HfBridge(_HfChannel(historyFirst: true, overrideCaps: caps));
      await _transport(b).handshake();
      expect(
        b.channel
            .callsOf('initializeConversationV4')
            .single
            .$2
            .containsKey('capabilities'),
        isFalse,
        reason: '非 === true 一律不声明：$caps',
      );
    }

    // 桥恢复清档（审查修复）：与 connectionId 同款处置。
    bridgeT.recovered.value++;
    expect(
      convT.hostCapabilities,
      isNull,
      reason: '对端可能换代，陈旧位残留=向不再声明该能力的 Host 回声明',
    );
  });

  test('runtimeInitialization：快照三态/补丁流转/缺席不门控', () {
    final state = ConversationState();
    expect(state.runtimeInitialization, isNull);
    expect(state.runtimeInitializationBlocked, isFalse, reason: '缺席=旧协议完整就绪语义');

    state.applyFrame(
      _snapFrame(
        _sessionSnap(runtimeInit: _runtimeInit('initializing', 'a1')),
        toSeq: 1,
      ),
      onGap: () => fail('unexpected gap'),
    );
    expect(state.runtimeInitializationBlocked, isTrue);
    expect(state.runtimeInitializationFailed, isFalse);

    state.applyFrame(
      _deltaFrame(1, 2, [
        {
          'op': 'state.updated',
          'patch': {'runtimeInitialization': _runtimeInit('ready', 'a1')},
        },
      ]),
      onGap: () => fail('unexpected gap'),
    );
    expect(state.runtimeInitializationBlocked, isFalse);

    state.applyFrame(
      _deltaFrame(2, 3, [
        {
          'op': 'state.updated',
          'patch': {
            'runtimeInitialization': _runtimeInit(
              'failed',
              'a2',
              reasonCode: 'fault.subscribe.resumeFailed',
              message: 'boom',
            ),
          },
        },
      ]),
      onGap: () => fail('unexpected gap'),
    );
    expect(state.runtimeInitializationFailed, isTrue);
    expect(state.runtimeInitialization?['attemptId'], 'a2');
    expect(state.runtimeInitialization?['message'], 'boom');
  });

  test('applySeed 保真种子 runtimeInitialization（水位不变量，审查修复 P1）', () {
    // 种子与 base 水位必须一致（pendingInteractions 同款教训）：resume
    // 续传零重放时该值就是服务端权威态——剥除会让 failed 态在「重开
    // app」主路径永久丢失（重试入口不可达）。
    final state = ConversationState()
      ..applySeed(
        ConversationSeed(
          rows: const [],
          logEpoch: 'e1',
          seq: 2,
          firstRowId: 1,
          totalCount: 0,
          snapshot: {
            'title': 't',
            'runtimeInitialization': _runtimeInit('failed', 'att-1'),
          },
        ),
      );
    expect(
      state.runtimeInitializationFailed,
      isTrue,
      reason: '种子值保留（服务端 resume 承认水位时不重发）',
    );
    expect(state.runtimeInitialization?['attemptId'], 'att-1');
  });

  test('订阅链：retryInitialization 携带 attemptId；ACK 后清除（桥恢复重订阅不再携带）', () async {
    final bridge = _HfBridge(_HfChannel());
    final conv = _transport(bridge);
    final sub = await conv.subscribe('s1');
    try {
      bridge.channel.emitConversationFrame(
        's1',
        _snapFrame(
          _sessionSnap(
            runtimeInit: _runtimeInit(
              'failed',
              'att-9',
              reasonCode: 'x',
              message: 'm',
            ),
          ),
          toSeq: 1,
        ),
      );
      await _until(() => sub.state.runtimeInitializationFailed);
      expect(sub.state.runtimeInitialization?['attemptId'], 'att-9');

      await conv.retryInitialization('s1');
      final subs = bridge.channel.callsOf('subscribeConversationV4');
      expect(subs.length, 2, reason: '失败重试=一次重订阅');
      expect(subs.last.$2['retryInitialization'], 'att-9');

      // ACK 已清意图：桥恢复触发的自动重订阅不得再携带（官方语义：普通
      // 重连不重跑失败尝试）。
      bridge.recovered.value++;
      await _until(
        () => bridge.channel.callsOf('subscribeConversationV4').length == 3,
      );
      // 轮2 加严：#2（retry 那发）之后**所有**订阅调用都不得携带——
      // 只查 .last 会漏看自动链多发的中间发。
      final subsAfter = bridge.channel.callsOf('subscribeConversationV4');
      for (var i = 2; i < subsAfter.length; i++) {
        expect(
          subsAfter[i].$2.containsKey('retryInitialization'),
          isFalse,
          reason: '第 ${i + 1} 发不得携带（官方单次 connect 语义）',
        );
      }
    } finally {
      await sub.dispose();
    }
  });

  test('retry 门控：非 failed 态（initializing）不触发重订阅', () async {
    final bridge = _HfBridge(_HfChannel());
    final conv = _transport(bridge);
    final sub = await conv.subscribe('s1');
    try {
      bridge.channel.emitConversationFrame(
        's1',
        _snapFrame(
          _sessionSnap(runtimeInit: _runtimeInit('initializing', 'a1')),
          toSeq: 1,
        ),
      );
      await _until(() => sub.state.runtimeInitializationBlocked);
      await conv.retryInitialization('s1');
      expect(
        bridge.channel.callsOf('subscribeConversationV4').length,
        1,
        reason: 'initializing 不可重试（服务端也只认 failed attemptId）',
      );
    } finally {
      await sub.dispose();
    }
  });

  test('host=false：retryInitialization 不随订阅携带（strict 防线，T2）', () async {
    final bridge = _HfBridge(_HfChannel(historyFirst: false));
    final conv = _transport(bridge);
    final sub = await conv.subscribe('s1');
    try {
      bridge.channel.emitConversationFrame(
        's1',
        _snapFrame(
          _sessionSnap(
            runtimeInit: _runtimeInit('failed', 'att-1', message: 'm'),
          ),
          toSeq: 1,
        ),
      );
      await _until(() => sub.state.runtimeInitializationFailed);
      await conv.retryInitialization('s1');
      final subs = bridge.channel.callsOf('subscribeConversationV4');
      expect(subs.length, 2);
      expect(
        subs.last.$2.containsKey('retryInitialization'),
        isFalse,
        reason: 'host 未声明 historyFirst 时带顶层未知键=旧桌面 strict 失败',
      );
    } finally {
      await sub.dispose();
    }
  });

  test('retry 意图发出即消费：订阅 RPC 失败后的自动重订阅不携带（P4）', () async {
    final bridge = _HfBridge(_HfChannel());
    final conv = _transport(bridge);
    final sub = await conv.subscribe('s1');
    try {
      bridge.channel.emitConversationFrame(
        's1',
        _snapFrame(
          _sessionSnap(
            runtimeInit: _runtimeInit('failed', 'att-2', message: 'm'),
          ),
          toSeq: 1,
        ),
      );
      await _until(() => sub.state.runtimeInitializationFailed);
      bridge.channel.failNextSubscribe = true;
      await conv.retryInitialization('s1');
      // retry 的那次订阅 RPC 已携带意图并消费（即使它失败了）——
      // 桥恢复触发的自动重订阅不得再携带（官方 store.retry 单次语义）。
      bridge.recovered.value++;
      await _until(
        () => bridge.channel.callsOf('subscribeConversationV4').length == 3,
      );
      expect(
        bridge.channel
            .callsOf('subscribeConversationV4')
            .last
            .$2
            .containsKey('retryInitialization'),
        isFalse,
      );
    } finally {
      await sub.dispose();
    }
  });

  test('mergeBlockedVoiceDraft：空输入回填/有草稿合并一行（U4/T1）', () {
    expect(mergeBlockedVoiceDraft('', '口述内容'), '口述内容');
    expect(mergeBlockedVoiceDraft('  ', '口述内容'), '口述内容');
    expect(
      mergeBlockedVoiceDraft('已有草稿', '口述内容'),
      '已有草稿' + '\n' + '口述内容',
      reason: '有草稿时合并不覆盖——长按语音允许带草稿开面板',
    );
  });

  hfUiTests();
}

// ---- UI 面：发送门控/失败条/重试 ----

class _HfSub implements ConversationSubscription {
  _HfSub(this.state);
  @override
  final ConversationState state;

  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-hf';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s1';
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HfApp extends AppState {
  _HfApp(this.sub);
  final _HfSub sub;
  final sentTexts = <String>[];
  final retryCalls = <String?>[];
  // 非空桥=在线（_sendText 离线入队分支按 bridge==null 判定，不注入
  // 会把发送吞进离线队列）。
  @override
  final BridgeSession bridge = _HfBridge(_HfChannel());
  @override
  Future<void> retryInitialization(String sessionId) async {
    retryCalls.add(sub.state.runtimeInitialization?['attemptId'] as String?);
  }

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    Object? seedCacheEntry,
  }) async {
    return sub;
  }

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
}

Widget _uiHost(_HfApp app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const ConversationPage(sessionId: 's1', title: '冷会话'),
  ),
);

ConversationState _seededState() {
  final state = ConversationState()
    ..applySeed(
      ConversationSeed(
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '早', 'createdAt': 1},
        ],
        logEpoch: 'e1',
        seq: 1,
        firstRowId: 1,
        totalCount: 1,
        snapshot: {
          'title': '冷会话',
          'control': const {'phase': 'idle'},
        },
      ),
    );
  return state;
}

void _injectRuntimeInit(ConversationState state, Map<String, dynamic> ri) {
  state.snapshot = {...state.snapshot ?? {}, 'runtimeInitialization': ri};
  state.notifyListeners();
}

void hfUiTests() {
  testWidgets('initializing：历史可读、发送键禁用不发 RPC；ready 后恢复可发', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _seededState();
    _injectRuntimeInit(state, _runtimeInit('initializing', 'a1'));
    final app = _HfApp(_HfSub(state));
    await tester.pumpWidget(_uiHost(app));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 历史先行：冷会话首屏即可读（种子行渲染）。
    expect(find.text('早'), findsOneWidget);
    // T3：initializing 不显示提示条（官方口径：仅失败时显示）。
    expect(find.byKey(const ValueKey('runtime-init-failed')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'hello');
    await tester.pump();
    IconButton button() =>
        tester.widget<IconButton>(find.byKey(const ValueKey('send-button')));
    expect(button().onPressed, isNull, reason: 'runtimeBlocked 禁发');
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(app.sentTexts, isEmpty, reason: '不发注定被拒的 RPC');

    _injectRuntimeInit(state, _runtimeInit('ready', 'a1'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(button().onPressed, isNotNull, reason: 'ready 恢复');
    expect(find.byKey(const ValueKey('runtime-init-failed')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(app.sentTexts, ['hello']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed：失败条（含 message）+重试调 retryInitialization', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _seededState();
    _injectRuntimeInit(
      state,
      _runtimeInit(
        'failed',
        'att-7',
        reasonCode: 'fault.subscribe.resumeFailed',
        message: 'resume 失败',
      ),
    );
    final app = _HfApp(_HfSub(state));
    await tester.pumpWidget(_uiHost(app));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('runtime-init-failed')), findsOneWidget);
    expect(find.textContaining('初始化失败，暂时无法发送'), findsOneWidget);
    expect(find.textContaining('resume 失败'), findsOneWidget);

    // failed 态发送键同样禁发。
    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'x');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('send-button')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('runtime-init-retry')));
    await tester.pump();
    expect(app.retryCalls, ['att-7'], reason: '重试携带当前 failed attemptId');
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧桌面（无 runtimeInitialization）：无失败条、发送不受限', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _seededState();
    final app = _HfApp(_HfSub(state));
    await tester.pumpWidget(_uiHost(app));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('runtime-init-failed')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'hi');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('send-button')))
          .onPressed,
      isNotNull,
      reason: '缺席=旧协议完整就绪语义，不门控',
    );
    expect(tester.takeException(), isNull);
  });

  review2HistoryTests();
}

// ---- 审查轮2（tier-review-2-1120）补钉：history_first 侧 ----

/// U5 场景夹具：活订阅未就绪（state 不 ready）+ 缓存预渲携带 failed
/// runtimeInitialization——预渲层不得驱动运行时门控。
class _HfPreviewApp extends _HfApp {
  _HfPreviewApp(super.sub);

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '缓存里的旧消息', 'createdAt': 1},
        ],
        logEpoch: 'e1',
        lastSeq: 2,
        firstRowId: 1,
        totalCount: 1,
        snapshotControl: const {
          'title': '冷会话',
          'control': {'phase': 'idle'},
          'runtimeInitialization': {
            'status': 'failed',
            'attemptId': 'stale-att',
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

void review2HistoryTests() {
  testWidgets('轮2 U5：缓存预渲携带 failed 不驱动门控（红=改回 effState）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 活订阅 state 未就绪（不 applySeed→ready=false 且 rows 空）→ 页面走
    // 缓存预渲；预渲控制块携带陈旧 failed。
    final state = ConversationState();
    final app = _HfPreviewApp(_HfSub(state));
    await tester.pumpWidget(_uiHost(app));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('缓存里的旧消息'), findsOneWidget, reason: '预渲生效');
    expect(
      find.byKey(const ValueKey('runtime-init-failed')),
      findsNothing,
      reason: '预渲层陈旧 failed 不出失败条（U5）',
    );
    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'hello');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('send-button')))
          .onPressed,
      isNotNull,
      reason: '红=门控数据源改回 effState（预渲 failed 误禁发）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('轮2 U3：blocked+空草稿麦克风点按可达（InputBar 直泵）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var voiceOpened = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: InputBar(
            controller: controller,
            focusNode: FocusNode(),
            running: false,
            sending: false,
            runtimeBlocked: true,
            onSend: () {},
            onStop: () {},
            onVoice: () => voiceOpened++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('send-button')))
          .onPressed,
      isNotNull,
      reason: '红=内层分支加回 !runtimeBlocked（点按死长按活）',
    );
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(voiceOpened, 1, reason: '空草稿麦克风直达不受 runtimeBlocked 限制');
    // 对照：blocked+有草稿=禁用（不落麦克风）。
    controller.text = '草稿';
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('send-button')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('轮2 T4：blocked 期语音文本合并回填接线（debugSend 缝）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _seededState();
    _injectRuntimeInit(state, _runtimeInit('failed', 'a9', message: 'm'));
    final app = _HfApp(_HfSub(state));
    await tester.pumpWidget(_uiHost(app));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '已有草稿');
    await tester.pump();
    final page = tester.state(find.byType(ConversationPage));
    final ok = await (page as dynamic).debugSendTextForTest('口述内容') as bool;
    await tester.pump();
    expect(ok, isFalse, reason: 'blocked 拦发返回 false');
    expect(app.sentTexts, isEmpty);
    expect(
      find.text('已有草稿' + '\n' + '口述内容'),
      findsOneWidget,
      reason: '红=调用点改直覆盖（丢用户草稿）——纯函数之外的接线钉',
    );
  });

  testWidgets('轮2 U10：readOnly 会话不出初始化失败条', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _seededState();
    _injectRuntimeInit(state, _runtimeInit('failed', 'att-x', message: 'm'));
    final app = _HfApp(_HfSub(state));
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ConversationPage(
            sessionId: 's1',
            title: '只读下钻',
            readOnly: true,
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('runtime-init-failed')),
      findsNothing,
      reason: '红=去掉 !widget.readOnly 守卫',
    );
    expect(
      find.byKey(const ValueKey('chat-input')),
      findsNothing,
      reason: '只读页无输入栏（ReadOnlyBar 形态自证）',
    );
  });
}
