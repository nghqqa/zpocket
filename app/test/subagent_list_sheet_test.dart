// 会话子代理列表（2026-10-26 批④拍板，官方 SubagentSessionSidePane
// 手机化）：分段渲染（运行中/已结束）、endedCursor 分页加载、
// childSessionId 下钻只读会话、空/错误态。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/ui/conversation_page.dart';
import 'package:zpocket/ui/subagent_list_sheet.dart';

Map<String, dynamic> _item(
  String id,
  String title, {
  String? status,
  String? summary,
}) =>
    {
      'childSessionId': id,
      'subagentType': 'general-purpose',
      'title': title,
      if (summary != null) 'summary': summary,
      if (status != null) 'status': status,
      'startedAt': 1700000000000,
    };

class _FakeApp extends AppState {
  final Map<String, dynamic>? Function(String sessionId,
      {String? endedCursor, int endedLimit}) impl;
  _FakeApp(this.impl);

  /// 早前批次 ：stopControl 唯一来源=快照 subagents.running 投影
  ///（legacy RPC running 行官方 strict schema 无此字段）。
  final ConversationState projectionState = ConversationState();

  void seedProjection(List<Map<String, dynamic>> running) {
    projectionState.snapshot = {
      'subagents': {'revision': 1, 'running': running},
    };
  }

  @override
  Map<String, ConversationState> get conversationStates => {
        's-main': projectionState,
      };

  /// ② 逐条停止：按用例注入的 stopSubagent 结果。
  dynamic Function(String sessionId, String taskId, String execId)? stopImpl;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<Map<String, dynamic>?> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) async =>
      impl(sessionId,
          endedCursor: endedCursor, endedLimit: endedLimit);

  @override
  Future<dynamic> stopSubagent(
    String sessionId,
    String taskId,
    String executionId,
  ) async =>
      (stopImpl ?? (s, t, e) => {'status': 'accepted'})(sessionId, taskId, executionId);
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        // Scaffold 必须在场：停止失败的 SnackBar 需要
        // ScaffoldMessenger 有可呈现的 Scaffold（真实页面恒有）。
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showSubagentListSheet(
                context,
                sessionId: 's-main',
                openSession: (context, {required sessionId, required title, required readOnly}) async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ConversationPage(
                        sessionId: sessionId,
                        title: title,
                        readOnly: readOnly,
                      ),
                    ),
                  );
                },
              ),
              child: const Text('开'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

void main() {
  // 正常手机视口（默认 800×600 偏矮致弹层布局断言失真）。
  void setPhoneView(WidgetTester tester) {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('分段渲染：运行中+已结束（含失败红标），下钻只读会话',
      (tester) async {
    setPhoneView(tester);
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) => {
          'revision': 1,
          'childSessionIds': const ['c1', 'c2', 'c3'],
          'running': [_item('c1', '勘察工作区', summary: '正在读目录')],
          'ended': {
            'total': 2,
            'items': [
              _item('c2', '检索用法', status: 'success'),
              _item('c3', '写报告', status: 'failed'),
            ],
          },
        });
    await tester.pumpWidget(_host(app));
    await _open(tester);

    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已结束 2'), findsOneWidget);
    expect(find.textContaining('勘察工作区'), findsOneWidget);
    expect(find.textContaining('写报告 · 失败'), findsOneWidget,
        reason: '失败条目须有可读信号（红标题+失败后缀）');

    // 下钻：点运行中条目 → 推入只读会话页（2026-11-05 反馈①：标题优先
    // 用类型——官方 sidePaneTabPresentation L127 语义；类型即子代理身份，
    // 任务 title 仍在列表行可见）。
    // 有界泵：下钻页加载转圈是无限动画（pumpAndSettle 必超时）。
    await tester.tap(find.textContaining('勘察工作区'));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('general-purpose'), findsWidgets,
        reason: '下钻页顶栏标题=子代理类型');
    expect(Navigator.of(tester.element(find.text('general-purpose').first)).canPop(),
        isTrue);
  });

  testWidgets('分页：加载更多用 endedCursor 换页', (tester) async {
    final calls = <String?>[];
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) {
      calls.add(endedCursor);
      return {
        'revision': 1,
        'childSessionIds': const [],
        'running': const [],
        'ended': endedCursor == null
            ? {
                'total': 3,
                'items': [
                  _item('c1', '第一页甲'),
                  _item('c2', '第一页乙'),
                ],
                'nextCursor': 'cursor-1',
              }
            : {
                'total': 3,
                'items': [_item('c3', '第二页丙')],
              },
      };
    });
    await tester.pumpWidget(_host(app));
    await _open(tester);

    expect(find.byKey(const ValueKey('subagents-load-more')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('subagents-load-more')));
    await tester.pumpAndSettle();
    expect(calls, [null, 'cursor-1'], reason: '第二页带 endedCursor');
    expect(find.textContaining('第二页丙'), findsOneWidget);
    expect(find.byKey(const ValueKey('subagents-load-more')), findsNothing,
        reason: '无更多页时加载更多退场');
  });

  testWidgets('空态', (tester) async {
    setPhoneView(tester);
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) => {
          'revision': 0,
          'childSessionIds': const [],
          'running': const [],
          'ended': {'total': 0, 'items': const []},
        });
    await tester.pumpWidget(_host(app));
    await _open(tester);
    expect(find.textContaining('还没有子智能体'), findsOneWidget);
  });

  testWidgets('错误态可重试：恢复后显示完整空态面板', (tester) async {
    setPhoneView(tester);
    var calls = 0;
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) {
      calls++;
      if (calls == 1) return null;
      return {
        'revision': 0,
        'childSessionIds': const [],
        'running': const [],
        'ended': {'total': 0, 'items': const []},
      };
    });
    await tester.pumpWidget(_host(app));
    await _open(tester);
    expect(find.textContaining('加载失败'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subagents-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const ValueKey('subagents-empty')), findsOneWidget);
    expect(find.textContaining('主智能体创建子智能体后'), findsOneWidget);
  });

  // ② 逐条停止（早前批次+早前批次，官方 stopSubagent 命令）：
  // stopControl 唯一来源=快照 subagents.running 投影（live runtime 写入；
  // legacy RPC running 行官方 strict schema 无此字段——往 RPC 夹具注入
  // stopControl 属已知失败家族「夹具自发明形状」，本组已改投影源）；
  // payload {taskId, executionId} strict；failed ACK=not_running/not_found
  // 人话提示+本地陈旧行自愈移除。
  group('逐条停止', () {
    // RPC 运行行（官方 zcodeSessionRunningSubagentSchema——无 stopControl）。
    Map<String, dynamic> runningRpcRow() =>
        _item('c-run', '勘察工作区', summary: '正在读目录');

    // 投影运行行（官方 runningSubagentSummarySchema——stopControl 在场）。
    Map<String, dynamic> projectionRow({bool withControl = true}) => {
          'childSessionId': 'c-run',
          'subagentType': 'general-purpose',
          'title': '勘察工作区',
          'status': 'running',
          if (withControl)
            'stopControl': {'taskId': 'agent-7', 'executionId': 'exec-a'},
        };

    testWidgets('投影带 stopControl 的运行行出停止钮；accepted 后行移除',
        (tester) async {
      setPhoneView(tester);
      var loads = 0;
      final app = _FakeApp((s, {endedCursor, endedLimit = 20}) {
        loads++;
        // 首载=RPC 运行行；停止后的刷新=两端已收敛（空）。
        if (loads > 1) {
          return {
            'revision': 2,
            'childSessionIds': const [],
            'running': const [],
            'ended': {
              'total': 0,
              'items': const [],
            },
          };
        }
        return {
          'revision': 1,
          'childSessionIds': const ['c-run'],
          'running': [runningRpcRow()],
          'ended': {
            'total': 0,
            'items': const [],
          },
        };
      });
      app.seedProjection([projectionRow()]);
      final stops = <(String, String, String)>[];
      app.stopImpl = (sessionId, taskId, execId) {
        stops.add((sessionId, taskId, execId));
        return {'status': 'accepted'};
      };
      await tester.pumpWidget(_host(app));
      await _open(tester);

      expect(find.byKey(const ValueKey('subagent-stop-c-run')), findsOneWidget,
          reason: '红=旧实现从 RPC 行读 stopControl（真机永不出现）');
      await tester.tap(find.byKey(const ValueKey('subagent-stop-c-run')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 命令实参：sessionId + 投影 stopControl 的 taskId/executionId 原样。
      expect(stops, [('s-main', 'agent-7', 'exec-a')]);
      // accepted=乐观移除（投影随后收敛；_load 刷新兜底）。
      expect(find.textContaining('勘察工作区'), findsNothing);
    });

    testWidgets('投影无 stopControl（冷恢复行）不出停止钮', (tester) async {
      setPhoneView(tester);
      var stopCalled = false;
      final app = _FakeApp((s, {endedCursor, endedLimit = 20}) => {
            'revision': 1,
            'childSessionIds': const ['c-run'],
            'running': [runningRpcRow()],
            'ended': {
              'total': 0,
              'items': const [],
            },
          });
      // 投影行在场但无 stopControl（冷恢复形态）。
      app.seedProjection([projectionRow(withControl: false)]);
      app.stopImpl = (sessionId, taskId, execId) {
        stopCalled = true;
        return {'status': 'accepted'};
      };
      await tester.pumpWidget(_host(app));
      await _open(tester);

      expect(find.byKey(const ValueKey('subagent-stop-c-run')), findsNothing,
          reason: '官方同款门控：冷恢复投影行无 stopControl=不可停');
      expect(find.textContaining('勘察工作区'), findsOneWidget);
      expect(stopCalled, isFalse);
    });

    testWidgets('RPC 行在但投影无该行（投影先收敛）也不出停止钮',
        (tester) async {
      setPhoneView(tester);
      final app = _FakeApp((s, {endedCursor, endedLimit = 20}) => {
            'revision': 1,
            'childSessionIds': const ['c-run'],
            'running': [runningRpcRow()],
            'ended': {
              'total': 0,
              'items': const [],
            },
          });
      app.seedProjection(const []); // 投影已无此行（子代理刚结束）
      await tester.pumpWidget(_host(app));
      await _open(tester);
      expect(find.byKey(const ValueKey('subagent-stop-c-run')), findsNothing);
    });

    testWidgets('failed ACK not_running → 人话提示+陈旧行自愈移除',
        (tester) async {
      setPhoneView(tester);
      var loads = 0;
      final app = _FakeApp((s, {endedCursor, endedLimit = 20}) {
        loads++;
        // not_running=CLI 已终态：停止后的刷新应已收敛（真实语义）。
        if (loads > 1) {
          return {
            'revision': 2,
            'childSessionIds': const [],
            'running': const [],
            'ended': {
              'total': 0,
              'items': const [],
            },
          };
        }
        return {
          'revision': 1,
          'childSessionIds': const ['c-run'],
          'running': [runningRpcRow()],
          'ended': {
            'total': 0,
            'items': const [],
          },
        };
      });
      app.seedProjection([projectionRow()]);
      app.stopImpl = (sessionId, taskId, execId) => {
            'status': 'failed',
            'reasonCode': 'fault.command.subagentStopRejected.not_running',
          };
      await tester.pumpWidget(_host(app));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('subagent-stop-c-run')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.textContaining('该子代理已不在运行'),
        findsOneWidget,
        reason: '官方词表人话映射（不当成功、不裸协议码）',
      );
      // not_running=该行已陈旧：本地自愈移除（不再留可无限重点的钮）。
      expect(find.textContaining('勘察工作区'), findsNothing);
    });
  });
}
