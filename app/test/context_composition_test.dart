// ① 上下文组成下钻（早前批次）：v4/conversation/contextComposition
// 的 11 细类消费页——官方契约（context-composition/contract.ts:11-161）：
// categories 只含 tokens>0 的类别、固定枚举序；items≤50 按 token 降序；
// phase=request|draft-preview；composition:null=会话不在内存（人话空态）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/ui/context_composition_page.dart';

Map<String, dynamic> _compositionFixture() => {
      'sessionId': 's-1',
      'revision': 12,
      'phase': 'request',
      'measuredAt': 1763200000000,
      'model': {
        'providerId': 'zai',
        'modelId': 'glm-5.3',
        'contextWindow': 200000,
      },
      'tokenMethod': 'estimated',
      'estimatedTokens': 84210,
      'providerInputTokens': 79123,
      'providerContextTokens': 80345,
      'freeTokens': 115790,
      'categories': [
        {
          'id': 'system_prompt',
          'tokens': 5120,
          'chars': 20480,
          'items': [
            {'name': 'system', 'tokens': 5120},
          ],
        },
        {
          'id': 'system_tool_schemas',
          'tokens': 12044,
          'chars': 48176,
          'items': [
            {'name': 'Read', 'tokens': 900},
            {'name': 'Bash', 'tokens': 850},
          ],
        },
        {
          // 0 token 类别服务端不下发——夹具也只放非零类，渲染层仍按
          // 枚举序（system_prompt 在 tool_schemas 之前）。
          'id': 'messages',
          'tokens': 61000,
          'chars': 244000,
        },
      ],
    };

class _CmpApp extends AppState {
  final dynamic result;
  final Object? error;
  _CmpApp({this.result, this.error});

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> contextComposition(String sessionId) async {
    if (error != null) throw error!;
    return result;
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ContextCompositionPage(sessionId: 's-1'),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('compositionOf：裸对象语义（服务已解包 {composition} 信封）', () {
    expect(compositionOf(null), isNull);
    expect(compositionOf('oops'), isNull);
    // 早前批次 ：getContextComposition 返回裸 ContextComposition——
    // Map 即组成对象本身，不再读 ['composition'] 键。
    expect(compositionOf(const {'sessionId': 's-1'}), isNotNull);
    expect(
      compositionOf(const {'sessionId': 's-1'})!['sessionId'],
      's-1',
    );
  });

  testWidgets('渲染：模型头+phase+枚举序类别+占比', (tester) async {
    await _pump(
      tester,
      _host(_CmpApp(result: _compositionFixture())),
    );
    // 摘要卡：模型名 / 最近请求 phase / 总量。
    expect(find.text('glm-5.3'), findsOneWidget);
    expect(find.byKey(const ValueKey('ctxcomp-phase')), findsOneWidget);
    expect(find.text('最近请求'), findsOneWidget);
    // 类别按官方枚举序渲染（system_prompt → system_tool_schemas →
    // messages），官方词表 zh 标签。
    final spY = tester.getTopLeft(find.text('系统提示词')).dy;
    final stY = tester.getTopLeft(find.text('系统工具')).dy;
    final msgY = tester.getTopLeft(find.text('消息')).dy;
    expect(spY, lessThan(stY));
    expect(stY, lessThan(msgY),
        reason: '官方 contract.ts:11-23 枚举序，不按大小重排');
  });

  testWidgets('展开：类别行点按出条目（名称+token），再点收起', (tester) async {
    await _pump(
      tester,
      _host(_CmpApp(result: _compositionFixture())),
    );
    // 初始收起：条目名不可见。
    expect(find.text('Read'), findsNothing);
    await tester.tap(find.text('系统工具'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Bash'), findsOneWidget);
    await tester.tap(find.text('系统工具'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Read'), findsNothing);
  });

  testWidgets('无条目类别不可点（messages 无 items）', (tester) async {
    await _pump(
      tester,
      _host(_CmpApp(result: _compositionFixture())),
    );
    await tester.tap(find.text('消息'));
    await tester.pump(const Duration(milliseconds: 200));
    // 仍收起（无 chevron、无条目行）。
    expect(find.byKey(const ValueKey('ctxcomp-cat-messages')), findsOneWidget);
  });

  testWidgets('composition:null → 人话空态（会话不在内存）', (tester) async {
    await _pump(tester, _host(_CmpApp(result: null)));
    expect(
      find.textContaining('暂无可用的上下文组成'),
      findsOneWidget,
      reason: '官方语义 null≠错误：会话不在内存不冷启动，人话空态',
    );
  });

  testWidgets('加载失败 → 错误+重试', (tester) async {
    await _pump(tester, _host(_CmpApp(error: StateError('rpc down'))));
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('旧 CLI（-32601 method-not-found）→ 按官方语义降级空态',
      (tester) async {
    await _pump(
      tester,
      _host(
        _CmpApp(
          error: StateError('ChannelRpcError: -32601 Method not found'),
        ),
      ),
    );
    expect(find.textContaining('暂无可用的上下文组成'), findsOneWidget,
        reason: '官方 contextCompositionClient.ts:23——旧 CLI 不认识查询'
            '方法当作 null，不当错误');
    expect(find.textContaining('加载失败'), findsNothing);
  });

  testWidgets('体量上限：11 类全量 × 每类 50 条目可渲染不溢出', (tester) async {
    // 协议上限（contract.ts:26-29,86-88）：categories ≤11（0 token 不下
    // 发——全 11 类即满配）、每类 items ≤50。满配渲染=体量答案。
    const ids = [
      'system_prompt', 'meta_user_context', 'skills', 'tool_prompt',
      'system_tool_schemas', 'mcp_tool_schemas', 'app_tool_schemas',
      'deferred_tool_schemas', 'reminders', 'compact_summary', 'messages',
    ];
    final composition = {
      'sessionId': 's-1',
      'revision': 1,
      'phase': 'request',
      'model': {
        'providerId': 'zai',
        'modelId': 'glm-5.3',
        'contextWindow': 200000,
      },
      'estimatedTokens': 90000,
      'freeTokens': 110000,
      'categories': [
        for (var c = 0; c < ids.length; c++)
          {
            'id': ids[c],
            'tokens': 8181 + c,
            'chars': 32724,
            'items': [
              for (var i = 0; i < 50; i++)
                {'name': '${ids[c]}-item-$i', 'tokens': 40 + i},
            ],
          },
      ],
    };
    await _pump(
      tester,
      _host(_CmpApp(result: composition)),
    );
    // 11 类全在场（枚举序；ListView 懒构建——折叠线以下先滚到再断言）。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ctxcomp-cat-messages')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('ctxcomp-cat-messages')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ctxcomp-cat-compact_summary')),
      findsOneWidget,
    );
    // 展开满配类：50 条渲染完整（列表内滚动无溢出断言）。
    await tester.tap(find.text('消息'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.scrollUntilVisible(
      find.text('messages-item-0'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('messages-item-0'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: '满配 11×50 渲染不得抛布局异常');
  });
}
