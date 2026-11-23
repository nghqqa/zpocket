import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/ui/conversation_message_cells.dart';
import 'package:zpocket/ui/conversation_page.dart';
import 'package:zpocket/ui/conversation_search.dart';
import 'package:zpocket/ui/conversation_turn_view.dart';
import 'package:zpocket/ui/turn_model.dart';

class _SearchSub implements ConversationSubscription {
  _SearchSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-search-enhance';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _EnhanceSearchApp extends AppState {
  _EnhanceSearchApp(
    this.initialRows,
    this.olderPages,
    this.sessionId,
  ) {
    uiPrefs.debugMarkLoadedForTest();
  }

  final List<Map<String, dynamic>> initialRows;
  final List<List<Map<String, dynamic>>> olderPages;
  final String sessionId;
  final String conversationPhase = 'completed';
  late final sub = _SearchSub(sessionId);

  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    if (!sub.state.ready) {
      final fullHistory = olderPages.isEmpty;
      sub.state.applySeed(
        ConversationSeed(
          rows: initialRows,
          logEpoch: 'e1',
          seq: initialRows.length,
          firstRowId: fullHistory
              ? (initialRows.first['rowId'] as num?)?.toInt()
              : 1,
          totalCount: fullHistory ? initialRows.length : 500,
          snapshot: {
            'title': '搜索加固测试',
            'control': {'phase': conversationPhase},
          },
        ),
      );
    }
    return sub;
  }

  @override
  Future<void> loadOlder(String sessionId) async {
    if (olderPages.isEmpty) {
      sub.state.prependOlderRows(const [], null, hasMore: false);
      return;
    }
    final page = olderPages.removeAt(0);
    sub.state.prependOlderRows(page, null, hasMore: olderPages.isNotEmpty);
  }
}

Widget _pageHost(_EnhanceSearchApp app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(sessionId: app.sessionId, title: '搜索加固测试'),
  ),
);

Widget _widgetHost(Widget child, {AppState? app}) {
  final effectiveApp = app ?? (AppState()..uiPrefs.debugMarkLoadedForTest());
  return AppStateScope(
    app: effectiveApp,
    child: MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _pump(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _noopOpenSession(
  BuildContext context, {
  required String sessionId,
  required String title,
  required bool readOnly,
}) async {}

void main() {
  tearDown(() {
    L10n.resetForTest();
    ConversationPage.debugResetScrollMemory();
    ConversationPage.debugResetToolFoldMemory();
  });

  group('ReDoS 预检与长文本正则扫描保护', () {
    test('isPotentiallyUnsafeRegex 拦截嵌套量词、量化交替与反向引用量词，放行安全模式', () {
      expect(isPotentiallyUnsafeRegex('(a+)+b'), isTrue);
      expect(isPotentiallyUnsafeRegex('(.*)+'), isTrue);
      expect(isPotentiallyUnsafeRegex('(.+)*'), isTrue);
      expect(isPotentiallyUnsafeRegex(r'(\w+){2,}'), isTrue);
      expect(isPotentiallyUnsafeRegex('((a|b)+)+'), isTrue);
      expect(isPotentiallyUnsafeRegex(r'([a-z]+\s*)+'), isTrue);
      // 扩防：量化交替重叠与嵌套交替
      expect(isPotentiallyUnsafeRegex(r'(a|aa)+$'), isTrue);
      expect(isPotentiallyUnsafeRegex(r'(\s|.)*END'), isTrue);
      expect(isPotentiallyUnsafeRegex('((a|aa))+'), isTrue);
      expect(isPotentiallyUnsafeRegex('(?:foo|bar)+'), isTrue);
      // 扩防：反向引用带量词
      expect(isPotentiallyUnsafeRegex(r'(a+)\1+'), isTrue);
      expect(isPotentiallyUnsafeRegex(r'(?<x>a+)\k<x>*'), isTrue);

      expect(isPotentiallyUnsafeRegex(r'(\d{4}-)+'), isFalse);
      expect(isPotentiallyUnsafeRegex('foo|bar'), isFalse);
      expect(isPotentiallyUnsafeRegex('(?:foo|bar)'), isFalse);
      expect(isPotentiallyUnsafeRegex(r'err\s+\d+'), isFalse);
      expect(isPotentiallyUnsafeRegex(r'\(a+\)+'), isFalse);
      expect(isPotentiallyUnsafeRegex('[a+]+'), isFalse);
      expect(isPotentiallyUnsafeRegex(r'(a)\1'), isFalse);

      final compiled = compileSearchRegex('(a+)+b');
      expect(compiled.regex, isNull);
      expect(compiled.error, '正则表达式过于复杂');

      final evilInput = '${'a' * 100}c';
      expect(
        findSearchMatchRanges(evilInput, '(a+)+b', useRegex: true),
        isEmpty,
      );

      final overWindow = '${'x' * 200500}needle';
      expect(
        findSearchMatchRanges(overWindow, 'needle', useRegex: true),
        isEmpty,
      );
    });

    testWidgets('搜索框输入 ReDoS 正则时内联报错且不卡顿', (tester) async {
      tester.view.physicalSize = const Size(375, 806);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = _EnhanceSearchApp(
        [
          {'rowId': 1, 'kind': 'userInput', 'text': '${'a' * 40}c'},
        ],
        [],
        's-redos-ui',
      );
      await tester.pumpWidget(_pageHost(app));
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('conversation-search-regex')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        '(a+)+b',
      );
      await _pump(tester, 5);

      expect(
        find.byKey(const ValueKey('conversation-search-regex-error')),
        findsOneWidget,
      );
      expect(find.text('正则表达式过于复杂'), findsOneWidget);
      expect(find.text('0/0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('多词短语优先高亮与计数一致', () {
    test('连续短语命中时仅高亮短语本身，不再标亮后面散落单词', () {
      const source = 'foo bar middle foo tail bar';
      final items = buildChatItems([
        {'rowId': 1, 'kind': 'userInput', 'text': source},
      ]);
      final matches = buildConversationSearchMatches(items, 'foo bar');
      expect(matches, hasLength(1));
      expect(matches.single.start, 0);
      expect(matches.single.end, 7);

      final ranges = findSearchMatchRanges(source, 'foo bar');
      expect(ranges, [(start: 0, end: 7)]);

      const base = TextStyle(color: Colors.black);
      const hit = TextStyle(color: Colors.blue);
      final spans = buildSearchHighlightSpans(
        source,
        'foo bar',
        base: base,
        hit: hit,
      );
      final hitTexts = spans
          .whereType<TextSpan>()
          .where((s) => s.style == hit)
          .map((s) => s.text)
          .toList();
      expect(hitTexts, ['foo bar']);

      // 无连续短语时退回多词 AND 全词高亮
      expect(
        findSearchMatchRanges('foo middle bar', 'foo bar'),
        [(start: 0, end: 3), (start: 11, end: 14)],
      );
    });
  });

  group('补拉最后一页与 200ms 防抖同步', () {
    test('补拉最后一页期间改词后出计数并自动触发定位', () async {
      final gate = Completer<bool>();
      final state = ConversationState()
        ..rows = [
          {'rowId': 10, 'kind': 'userInput', 'text': 'oldword'},
        ]
        ..firstRowId = 1
        ..totalCount = 2;
      final located = <ConversationSearchMatch>[];
      late final ConversationSearchController controller;
      controller = ConversationSearchController(
        stateProvider: () => state,
        itemsProvider: (s) => buildChatItems(s.rows),
        loadOlder: () async {
          final ok = await gate.future;
          if (ok) {
            state.prependOlderRows(
              [
                {'rowId': 0, 'kind': 'userInput', 'text': 'newword'},
              ],
              0,
              hasMore: false,
            );
          }
          return ok;
        },
        isAlive: () => true,
        onNotify: () {},
        onLocate: (m) async {
          controller.markLocated(m);
          located.add(m);
        },
        onAnchorMigrate: (_, _) {},
      );
      addTearDown(controller.dispose);

      controller.open();
      controller.controller.text = 'oldword';
      controller.change('oldword');
      expect(controller.loading, isTrue);

      controller.controller.text = 'newword';
      controller.change('newword');
      expect(controller.matches, isEmpty);
      expect(controller.locatedIdentity, isNull);

      gate.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(state.canLoadOlder, isFalse);
      expect(controller.matches, hasLength(1));
      expect(controller.matches.single.rowId, 0);
      expect(controller.locatedIdentity, controller.matches.single.identity);
      expect(located.last.rowId, 0);
    });

    testWidgets('200ms 防抖窗口内回车立即生效且不被晚到定时器二次重置', (tester) async {
      tester.view.physicalSize = const Size(375, 806);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = _EnhanceSearchApp(
        [
          {'rowId': 1, 'kind': 'userInput', 'text': 'alpha first'},
          {'rowId': 2, 'kind': 'userInput', 'text': 'beta one'},
          {'rowId': 3, 'kind': 'assistantText', 'text': 'beta two'},
        ],
        [],
        's-debounce-submit',
      );
      await tester.pumpWidget(_pageHost(app));
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        'alpha',
      );
      await _pump(tester, 4);
      expect(find.text('1/1'), findsOneWidget);

      // 切到 beta，仅推进 50ms（仍在 200ms 防抖窗口内）：计数条与气泡均未抢跑
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        'beta',
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('1/1'), findsOneWidget);

      // 立即按搜索/回车：立刻同步生效为 1/2
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);

      // 手动切到 2/2，再等超过 200ms，不能被残留防抖器重置回 1/2
      await tester.tap(find.byKey(const ValueKey('conversation-search-next')));
      await tester.pump();
      expect(find.text('2/2'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2/2'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('200ms 防抖窗口内切正则与含思考开关立即生效', (tester) async {
      tester.view.physicalSize = const Size(375, 806);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = _EnhanceSearchApp(
        [
          {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          {'rowId': 2, 'kind': 'userInput', 'text': '查看错误'},
          {'rowId': 3, 'kind': 'reasoning', 'text': 'hidden_reason_404'},
          {'rowId': 4, 'kind': 'assistantText', 'text': '返回 ERR 502'},
        ],
        [],
        's-debounce-toggle',
      );
      await tester.pumpWidget(_pageHost(app));
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        r'err\s+\d+',
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('conversation-search-regex')));
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1/1'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        'hidden_reason_404',
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.byKey(const ValueKey('conversation-search-reasoning')),
      );
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1/1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('思考块开关门控、临时展开点击与专用工具卡锚点', () {
    testWidgets('关闭含思考时手动展开思考块不高亮关键词', (tester) async {
      tester.view.physicalSize = const Size(375, 806);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = _EnhanceSearchApp(
        [
          {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          {'rowId': 2, 'kind': 'userInput', 'text': 'find needle here'},
          {
            'rowId': 3,
            'kind': 'reasoning',
            'state': 'completed',
            'text': 'thought needle hidden',
          },
          {'rowId': 4, 'kind': 'assistantText', 'text': 'done'},
        ],
        [],
        's-reasoning-gate',
      );
      await tester.pumpWidget(_pageHost(app));
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        'needle',
      );
      await _pump(tester, 5);
      expect(find.text('1/1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('user-search-highlight')),
        findsOneWidget,
      );

      // 展开回合工作条再手动展开思考块
      await tester.tap(
        find.descendant(
          of: find.byType(TurnBar),
          matching: find.byType(InkWell),
        ).first,
      );
      await _pump(tester, 6);
      await tester.tap(
        find.descendant(
          of: find.byType(ReasoningTile),
          matching: find.byType(InkWell),
        ).first,
      );
      await _pump(tester, 6);

      expect(find.text('thought needle hidden'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reasoning-search-highlight')),
        findsNothing,
      );
    });

    testWidgets('搜索临时展开思考块时点击可收起且关搜索不反锁常开', (tester) async {
      tester.view.physicalSize = const Size(375, 806);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = _EnhanceSearchApp(
        [
          {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          {'rowId': 2, 'kind': 'userInput', 'text': '排查问题'},
          {
            'rowId': 3,
            'kind': 'reasoning',
            'state': 'completed',
            'text': 'secret_dismiss_token',
          },
          {'rowId': 4, 'kind': 'assistantText', 'text': '已修复'},
        ],
        [],
        's-reasoning-dismiss',
      );
      await tester.pumpWidget(_pageHost(app));
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        'secret_dismiss_token',
      );
      await tester.tap(
        find.byKey(const ValueKey('conversation-search-reasoning')),
      );
      await _pump(tester, 6);

      expect(
        find.byKey(const ValueKey('reasoning-search-highlight')),
        findsOneWidget,
      );

      // 点击思考块标题收起
      await tester.tap(
        find.descendant(
          of: find.byType(ReasoningTile),
          matching: find.byType(InkWell),
        ).first,
      );
      await _pump(tester, 6);
      expect(
        find.byKey(const ValueKey('reasoning-search-highlight')),
        findsNothing,
      );

      // 关闭搜索后应维持收起，不反锁常开
      await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
      await _pump(tester, 6);
      await tester.tap(
        find.descendant(
          of: find.byType(TurnBar),
          matching: find.byType(InkWell),
        ).first,
      );
      await _pump(tester, 6);
      expect(find.text('secret_dismiss_token'), findsNothing);
    });

    testWidgets('流式思考块被搜索展开时标题读 _open，不残余单行摘要拼接', (tester) async {
      final widget = _widgetHost(
        ReasoningTile(
          row: const {
            'rowId': 3,
            'kind': 'reasoning',
            'state': 'streaming',
            'text': 'first line\nlatest summary line',
          },
          firstSeen: DateTime.now().subtract(const Duration(seconds: 3)),
          searchTargetRowId: 3,
          searchStart: 0,
        ),
      );
      await tester.pumpWidget(widget);
      await _pump(tester, 2);

      // _open 为 true 时，不应再拼「正在思考 · latest summary line」
      expect(find.textContaining('正在思考 · latest summary line'), findsNothing);
      expect(find.text('first line\nlatest summary line'), findsOneWidget);
    });

    testWidgets('FoldableUserText 手动展开后父级重建不折回，仅文本变更时重置', (tester) async {
      final longText = '${'长提问上下文行\n' * 14}末尾内容';
      var tick = 0;
      late StateSetter outerSetState;
      var currentText = longText;

      await tester.pumpWidget(
        _widgetHost(
          StatefulBuilder(
            builder: (context, setState) {
              outerSetState = setState;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('tick=$tick'),
                  FoldableUserText(
                    text: currentText,
                    selectable: (s) => Text(s),
                  ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('fold-expand')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fold-expand')));
      await tester.pump();
      expect(find.byKey(const ValueKey('fold-expand')), findsNothing);

      // 同文本触发父级重建（didUpdateWidget）：必须保持展开
      outerSetState(() => tick++);
      await tester.pump();
      expect(find.byKey(const ValueKey('fold-expand')), findsNothing);

      // 文本变化：重置回收起
      outerSetState(() {
        currentText = '${'更新后上下文行\n' * 14}新末尾内容';
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('fold-expand')), findsOneWidget);
    });

    testWidgets('TodoWrite / CreateWorkflow / OffPeakCreate / ExitPlanMode 均有 SearchTargetFrame', (
      tester,
    ) async {
      final rows = <Map<String, dynamic>>[
        {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedInterrupted'},
        {
          'rowId': 2,
          'kind': 'toolCall',
          'toolName': 'TodoWrite',
          'status': 'success',
          'input': {
            'todos': [
              {'content': 'todo needle', 'status': 'pending'},
            ],
          },
        },
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'CreateWorkflow',
          'toolCallId': 'tc-wf',
          'status': 'success',
          'input': {'label': 'wf needle'},
        },
        {
          'rowId': 4,
          'kind': 'toolCall',
          'toolName': 'OffPeakCreate',
          'status': 'success',
          'output': {
            'offPeakTaskId': 'op-1',
            'title': 'offpeak needle',
            'status': 'queued',
          },
        },
        {
          'rowId': 5,
          'kind': 'toolCall',
          'toolName': 'ExitPlanMode',
          'status': 'success',
          'input': {'plan': 'plan needle'},
        },
      ];
      final work = buildChatItems(rows).whereType<TurnBarItem>().first.work;

      for (final targetId in [2, 3, 4, 5]) {
        final targetKey = GlobalKey(debugLabel: 'target-$targetId');
        await tester.pumpWidget(
          _widgetHost(
            SingleChildScrollView(
              child: TurnBar(
                work: work,
                showTools: true,
                firstSeenOf: (_) => null,
                toolOpen: const {},
                elapsedMsOf: (_) => null,
                openSession: _noopOpenSession,
                searchTargetRowId: targetId,
                searchTargetKey: targetKey,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          targetKey.currentContext,
          isNotNull,
          reason: 'rowId=$targetId 应由 SearchTargetFrame 绑定 targetKey',
        );
      }
    });
  });
}
