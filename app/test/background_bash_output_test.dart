// 后台 Bash 输出详情（bg-bash-output-1，2026-11-20）：官方
// background-bash-output-details.md 交互合同的手机侧钉子——
// 打开立即查询/运行中 1s 轮询单在途/终态确认后补读一次再停/读取失败
// 保留上次内容+重试（BGV05）/退后台停轮询且迟到结果按代丢弃/回前台恢复/
// 列表 bash 行点开按 childSessionId 定向/subagent 行不可点/
// 3.19.0 resultSummary 终态摘要副行（缺席隐藏）。
// 红=旧实现无查询方法无详情页。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/ui/background_bash_output_page.dart';
import 'package:zpocket/ui/background_works_page.dart';

Map<String, dynamic> _output(String status, String text) => {
  'kind': 'output',
  'workId': 'w1',
  'status': status,
  'output': text,
  'truncated': false,
  'outputPath': r'C:\demo\out.log',
};

/// 队列假 fetch：逐步出结果，耗尽后恒返最后一档（稳态）。
class _QueueFetch {
  _QueueFetch(List<Future<dynamic> Function()> steps) : _steps = steps;
  final calls = <(String, String)>[];
  final List<Future<dynamic> Function()> _steps;
  int _i = 0;
  Future<dynamic> call(String sessionId, String workId) {
    calls.add((sessionId, workId));
    final i = _i < _steps.length ? _i++ : _steps.length - 1;
    return _steps[i]();
  }
}

Widget _host(Future<dynamic> Function(String, String) fetch) => MaterialApp(
  theme: buildAppTheme(),
  home: BackgroundBashOutputPage(
    sessionId: 's1',
    workId: 'w1',
    title: '跑构建脚本',
    fetch: fetch,
  ),
);

void main() {
  test('纯函数：六态人话/终态判定/响应归类/错误三联', () {
    expect(bashOutputStatusLabel('running'), '执行中');
    expect(bashOutputStatusLabel('timed_out'), '已超时');
    expect(bashOutputStatusLabel('spawn_error'), '启动失败');
    expect(bashOutputTerminal('running'), isFalse);
    for (final s in [
      'completed',
      'failed',
      'timed_out',
      'cancelled',
      'spawn_error',
    ]) {
      expect(bashOutputTerminal(s), isTrue, reason: s);
    }
    expect(bashOutputResultOf(_output('running', 'x'))?['status'], 'running');
    expect(bashOutputResultOf({'kind': 'unavailable', 'workId': 'w1'}), isNull);
    expect(bashOutputResultOf(<String, dynamic>{}), isNull);
    expect(bashOutputResultOf('oops'), isNull);
    expect(bashOutputErrorLabel('unavailable'), '输出暂不可用（任务记录不在内存中）');
    expect(bashOutputErrorLabel('unsupported'), '当前桌面版本不支持查看输出');
    expect(bashOutputErrorLabel('read_failed'), '读取输出失败');
    expect(bashOutputErrorLabel('anything'), '读取输出失败');
  });

  testWidgets('打开立即查询；运行中 1s 轮询；单在途；终态补读一次后停', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gate = Completer<dynamic>();
    final fetch = _QueueFetch([
      () async => _output('running', 'step 1'),
      () => gate.future,
    ]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump(); // postFrame 立即查询
    expect(fetch.calls.length, 1, reason: '打开立即查询');
    expect(find.textContaining('step 1'), findsOneWidget);
    expect(find.text('执行中'), findsOneWidget);
    expect(find.byKey(const ValueKey('bash-output-copy')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 2, reason: '运行中 1s tick 轮询');
    // 在途挂起期间不再发（单在途）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 2, reason: '最多一个在途');

    gate.complete(_output('completed', 'step 1\nstep 2 final'));
    await tester.pump();
    await tester.pump();
    expect(fetch.calls.length, 3, reason: '终态确认后补读一次尾部');
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('step 2 final'), findsOneWidget);
    // 终态停轮询：后续 tick 不再发。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 3, reason: '终态后停轮询');
    expect(tester.takeException(), isNull);
  });

  testWidgets('直接打开终态任务：立即查询+补读，不起轮询', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fetch = _QueueFetch([() async => _output('failed', 'error tail')]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    await tester.pump();
    expect(fetch.calls.length, 2, reason: '首查+终态补读');
    expect(find.text('失败'), findsOneWidget);
    expect(find.textContaining('error tail'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(fetch.calls.length, 2, reason: '终态无轮询');
    expect(tester.takeException(), isNull);
  });

  testWidgets('体量：接近 8KiB 上限输出卡片内滚动可达尾部（b volume）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 官方固定尾读 8192 bytes——构造 ~8KiB 多行输出（单个巨型
    // SelectableText 的 hitTestable 判定不可靠，以拖到底+滚动位置钉死）。
    final big = List.generate(
      250,
      (i) => 'line ${i + 1} build step detail ok',
    ).join('\n');
    expect(big.length, lessThanOrEqualTo(8192));
    final fetch = _QueueFetch([() async => _output('running', big)]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    expect(find.textContaining('line 1'), findsOneWidget);
    final scrollFinder = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollFinder).position;
    expect(position.maxScrollExtent, greaterThan(1000), reason: '8KiB 输出远超一屏');
    var guard = 0;
    while (position.pixels < position.maxScrollExtent - 1 && guard++ < 60) {
      await tester.drag(scrollFinder, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(position.pixels, position.maxScrollExtent, reason: '拖到尾部');
    expect(find.textContaining('line 250'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读取失败保留上次内容并停轮询；重试恢复（BGV05）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fetch = _QueueFetch([
      () async => _output('running', 'partial out'),
      () async => throw StateError('rpc dead'),
      () async => _output('running', 'partial out\nmore'),
    ]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    expect(find.textContaining('partial out'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 2);
    expect(find.textContaining('读取输出失败'), findsOneWidget, reason: '异常→人话错误');
    expect(
      find.textContaining('partial out'),
      findsOneWidget,
      reason: '保留上次内容',
    );
    await tester.pump(const Duration(seconds: 3));
    expect(fetch.calls.length, 2, reason: '失败后停轮询');

    await tester.tap(find.byKey(const ValueKey('bash-output-retry')));
    await tester.pump();
    await tester.pump();
    expect(fetch.calls.length, 3);
    expect(find.textContaining('partial out'), findsOneWidget);
    expect(find.textContaining('more'), findsOneWidget, reason: '重试取回最新');
    expect(find.text('执行中'), findsOneWidget, reason: '运行中恢复轮询');
    expect(tester.takeException(), isNull);
  });

  testWidgets('kind=unavailable 人话错误 + 无内容态重试入口', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fetch = _QueueFetch([
      () async => {'kind': 'unavailable', 'workId': 'w1'},
    ]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    expect(find.text('输出暂不可用（任务记录不在内存中）'), findsOneWidget);
    expect(find.byKey(const ValueKey('bash-output-retry')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bash-output-copy')),
      findsNothing,
      reason: '无成功内容不出复制钮',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('退后台停轮询并丢弃迟到结果；回前台恢复查询', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gate = Completer<dynamic>();
    final fetch = _QueueFetch([
      () async => _output('running', 'v1'),
      () => gate.future,
      () async => _output('running', 'v2'),
    ]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    expect(find.textContaining('v1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 2, reason: '在途');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    gate.complete(_output('running', 'STALE'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('STALE'), findsNothing, reason: '迟到结果按代丢弃');
    await tester.pump(const Duration(seconds: 5));
    expect(fetch.calls.length, 2, reason: '后台无轮询');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(fetch.calls.length, 3, reason: '回前台立即补查');
    expect(find.textContaining('v2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('在途请求跨退后台：回前台续发新查询并恢复轮询（审查修复 U1）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gate = Completer<dynamic>();
    final fetch = _QueueFetch([
      () async => _output('running', 'v1'),
      () => gate.future,
      () async => _output('running', 'v2'),
    ]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    expect(find.textContaining('v1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 2, reason: 'tick 在途');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(fetch.calls.length, 2, reason: '在途未归，恢复查询挂起不并发');

    gate.complete(_output('running', 'STALE'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('STALE'), findsNothing, reason: '旧代结果丢弃');
    expect(fetch.calls.length, 3, reason: '丢弃出口续发恢复查询');
    expect(find.textContaining('v2'), findsOneWidget);
    // 轮询已恢复：下一 tick 再查（旧实现此处永久停摆）。
    await tester.pump(const Duration(seconds: 1));
    expect(fetch.calls.length, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首载在途退后台回前台：补查出结果不卡加载（审查修复 U2）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gate = Completer<dynamic>();
    final fetch = _QueueFetch([
      () => gate.future,
      () async => _output('running', 'v1'),
    ]);
    await tester.pumpWidget(_host(fetch.call));
    await tester.pump();
    expect(fetch.calls.length, 1, reason: '首查在途');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    gate.complete(_output('running', 'STALE'));
    await tester.pump();
    expect(find.textContaining('STALE'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(fetch.calls.length, 2, reason: '回前台补查（旧实现永久 loading）');
    expect(find.textContaining('v1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  listEntryTests();
}

// ---- 列表页集成（bg-bash-output-1 的入口面）----

ConversationSeed _worksSeed(List<Map<String, dynamic>> works) =>
    ConversationSeed(
      rows: const [
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '跑构建',
          'createdAt': 1700000000000,
        },
      ],
      logEpoch: 'e1',
      seq: 1,
      firstRowId: 1,
      totalCount: 1,
      snapshot: {
        'title': '后台工作会话',
        'control': const {'phase': 'idle'},
        'backgroundWorks': works,
      },
    );

void listEntryTests() {
  testWidgets('bash 行点开详情（childSessionId 定向）；subagent 行不可点', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = ConversationState()
      ..applySeed(
        _worksSeed([
          {
            'workId': 'w-bash',
            'kind': 'bash',
            'title': '子代理里的构建',
            'status': 'running',
            'cancellable': true,
            'startedAt': 1,
            'anchorRowId': 1,
            'childSessionId': 'child-9',
          },
          {
            'workId': 'w-sub',
            'kind': 'subagent',
            'title': '视觉走查',
            'status': 'running',
            'startedAt': 2,
            'anchorRowId': 1,
          },
        ]),
      );
    final calls = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: BackgroundWorksPage(
          sessionId: 's1',
          state: state,
          fetchBashOutput: (sid, workId) async {
            calls.add((sid, workId));
            return {'kind': 'unavailable', 'workId': workId};
          },
          onCancel: (_, __) async {},
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('background-work-open-w-bash')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('background-work-open-w-sub')),
      findsNothing,
      reason: '非 bash 行无点开入口',
    );

    await tester.tap(find.byKey(const ValueKey('background-work-open-w-bash')));
    await tester.pump(); // 路由推入
    await tester.pump(); // postFrame 首查
    expect(find.byType(BackgroundBashOutputPage), findsOneWidget);
    expect(calls, [
      ('child-9', 'w-bash'),
    ], reason: '子会话任务按 childSessionId 定向（服务端沿 parentID 找归属）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('轮2 U7：childSessionId 空白串视同缺席回落当前会话', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = ConversationState()
      ..applySeed(
        _worksSeed([
          {
            'workId': 'w-blank',
            'kind': 'bash',
            'title': '空白子会话',
            'status': 'running',
            'startedAt': 1,
            'anchorRowId': 1,
            'childSessionId': '   ',
          },
        ]),
      );
    final calls = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: BackgroundWorksPage(
          sessionId: 's1',
          state: state,
          fetchBashOutput: (sid, workId) async {
            calls.add((sid, workId));
            return {'kind': 'unavailable', 'workId': workId};
          },
          onCancel: (_, __) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('background-work-open-w-blank')),
    );
    await tester.pump();
    await tester.pump();
    expect(calls, [('s1', 'w-blank')], reason: '红=空串原样下发（首查必错）');
  });

  testWidgets('resultSummary 终态摘要副行（3.19.0）；缺席隐藏', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = ConversationState()
      ..applySeed(
        _worksSeed([
          {
            'workId': 'w-f',
            'kind': 'bash',
            'title': '失败任务',
            'status': 'failed',
            'resultSummary': 'exit 1: build error',
            'startedAt': 1,
            'anchorRowId': 1,
          },
        ]),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: BackgroundWorksPage(
          sessionId: 's1',
          state: state,
          fetchBashOutput: (_, __) async => {'kind': 'unavailable'},
          onCancel: (_, __) async {},
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('background-work-summary-w-f')),
      findsOneWidget,
    );
    expect(find.text('exit 1: build error'), findsOneWidget);

    // 旧桌面无该字段 → 副行消失。
    state.applySeed(
      _worksSeed([
        {
          'workId': 'w-f',
          'kind': 'bash',
          'title': '失败任务',
          'status': 'failed',
          'startedAt': 1,
          'anchorRowId': 1,
        },
      ]),
    );
    state.notifyListeners();
    await tester.pump();
    expect(find.text('exit 1: build error'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
