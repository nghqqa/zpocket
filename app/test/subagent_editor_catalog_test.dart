import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/transport/channel_client.dart';
import 'package:zpocket/transport/companion_client.dart';
import 'package:zpocket/transport/conversation.dart';
import 'package:zpocket/transport/rpc_frame_transport.dart';
import 'package:zpocket/ui/subagents_page.dart';

class _AgentChannel extends ChannelClient {
  _AgentChannel() : super(sendBody: (_) {});
  Map<String, dynamic>? created;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'list':
        return {'userAgents': [], 'agents': [], 'pluginAgents': []};
      case 'createAgent':
        created = (args.first as Map).cast<String, dynamic>();
        return {'ok': true};
      case 'getView':
        return {
          'providers': [
            {
              'providerId': 'prov-a',
              'providerName': '个人套餐',
              'models': [
                {
                  'modelId': 'glm-test',
                  'config': {
                    'optionSpecs': {
                      'reasoningLevel': {
                        'values': ['low', 'high'],
                      },
                    },
                  },
                },
              ],
            },
          ],
        };
      default:
        return {};
    }
  }
}

class _AgentBridge implements BridgeSession {
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
  final ChannelClient channels = _AgentChannel();
  @override
  String? get workspaceKey => 'ws-agent';
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

class _AgentApp extends AppState {
  @override
  final BridgeSession bridge = _AgentBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspacePath': '/example-workspace',
    'workspaceIdentity': 'ws-agent',
  };

  /// 分组测试注入的多 provider 目录；null=默认单目录。
  List<dynamic>? optionsOverride;

  @override
  Future<List<dynamic>> modelSelectionOptions() async =>
      optionsOverride ??
      [
        ConfigOption.fromMap({
          'id': 'model',
          'name': 'Model',
          'options': const [
            {
              'value': 'prov-a/glm-test',
              'name': 'glm-test',
              'modelProviderId': 'prov-a',
              'modelThoughtLevels': ['low', 'high'],
            },
          ],
        }),
      ];
}

void main() {
  testWidgets('对抗审查③：空目录（装载窗口期/失败）弹层不崩，仅「继承默认」', (tester) async {
    final app = _AgentApp();
    app.optionsOverride = []; // 目录装载失败/在途的空形态
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const SubagentsPage()),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('subagent-new')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('editor-model-picker')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '空目录 ordered.first 崩溃回归');
    expect(
      find.byKey(const ValueKey('subagent-model-inherit')),
      findsOneWidget,
      reason: '空目录仍只有「继承默认」行（与旧 Dropdown 空目录行为等价）',
    );
    expect(find.byType(ConstrainedBox), findsWidgets);
  });

  testWidgets('对抗审查③：英文下模型行「继承默认」label 翻译无中文残留', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    addTearDown(L10n.resetForTest);
    final app = _AgentApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const SubagentsPage()),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('subagent-new')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Inherit default'), findsWidgets,
        reason: '编辑器模型行 label 预翻译（translate:false 下须构造侧 tr）；'
            '思考档下拉的既有 null 项同译合法');
    expect(find.text('继承默认'), findsNothing);
    expect(L10n.missingTranslations, isEmpty);
  });


  testWidgets('1.0.9 验收：模型选择按 provider 分组（组头短名+套餐徽标+组内去重）', (tester) async {
    final app = _AgentApp();
    // 双 provider 目录：zai 个人套餐组 + bigmodel API 组；同 provider 内
    // 同名 modelId 去重（跨 provider 各自成行）。
    app.optionsOverride = [
      ConfigOption.fromMap({
        'id': 'model',
        'name': 'Model',
        'options': const [
          {
            'value': 'zai-plan/glm-5.3',
            'name': 'GLM-5.3',
            'modelProviderId': 'account:individual-coding-plan-zai',
            'modelAccessMode': 'individual-coding-plan',
            'modelAccessAccountType': 'zai',
          },
          {
            'value': 'zai-plan/glm-5.3-air',
            'name': 'GLM-5.3-Air',
            'modelProviderId': 'account:individual-coding-plan-zai',
            'modelAccessMode': 'individual-coding-plan',
            'modelAccessAccountType': 'zai',
          },
          {
            'value': 'bigmodel-api/glm-5.3',
            'name': 'GLM-5.3',
            'modelProviderId': 'bigmodel-api',
          },
          {
            'value': 'bigmodel-api/glm-5.3-dup',
            'name': 'GLM-5.3',
            'modelProviderId': 'bigmodel-api',
          },
          {
            // 对抗审查④中1：真·同 provider 同 modelId 变体（dedup 键
            // 完全相同的多渠道条目）——modelDedupKey 应归并首见，
            // 不产生第二行。
            'value': 'bigmodel-api/glm-5.3-flash',
            'name': 'GLM-5.3-Flash',
            'modelProviderId': 'bigmodel-api',
          },
        ],
      }),
    ];
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const SubagentsPage()),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('subagent-new')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.enterText(find.byType(TextField).at(0), 'group-agent');
    await tester.enterText(find.byType(TextField).at(1), '分组测试');
    await tester.enterText(find.byType(TextField).at(2), '测试分组选择');

    await tester.tap(find.byKey(const ValueKey('editor-model-picker')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 组头：套餐组在前（Z.AI+个人徽标），API 组在后（BigModel+API 徽标）。
    expect(find.text('Z.AI'), findsOneWidget);
    expect(find.text('个人'), findsOneWidget);
    expect(find.text('BigModel API'), findsOneWidget);
    expect(find.text('API'), findsOneWidget);
    // 套餐组默认展开（无选中=首组），其模型行可见。
    expect(
      find.byKey(const ValueKey('subagent-model-option-zai-plan/glm-5.3')),
      findsOneWidget,
    );

    // 展开 BigModel API 组，选 API 渠道同名模型。
    final apiHeader = find.text('BigModel API');
    await Scrollable.ensureVisible(
      tester.element(apiHeader),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(apiHeader);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 同 provider 内按 modelId 去重：glm-5.3 与 glm-5.3-dup 名同为
    // GLM-5.3 但 value 不同——modelIdOf 取 '/' 后段，两者去重键不同
    // （glm-5.3/glm-5.3-dup），均保留；断言 API 渠道行存在。
    expect(
      find.byKey(const ValueKey('subagent-model-option-bigmodel-api/glm-5.3')),
      findsOneWidget,
    );
    // 同 provider 内不同 modelId 不误合并（dup 行保留）。
    expect(
      find.byKey(const ValueKey('subagent-model-option-bigmodel-api/glm-5.3-dup')),
      findsOneWidget,
    );
    // 同 provider 同 modelId（同 dedup 键）归并为一行——两条 flash
    // 条目只渲染首见（模型行 count 断言防第二行出现）。
    expect(
      find.byKey(const ValueKey('subagent-model-option-bigmodel-api/glm-5.3-flash')),
      findsOneWidget,
    );
    final apiOption = find.byKey(
      const ValueKey('subagent-model-option-bigmodel-api/glm-5.3'),
    );
    await Scrollable.ensureVisible(
      tester.element(apiOption),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(apiOption);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 行 label 回显所选模型名；保存后 config.model 携带 provider/model。
    expect(find.text('GLM-5.3'), findsWidgets);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final channel = app.bridge.channels as _AgentChannel;
    final config = channel.created?['config'] as Map<String, dynamic>?;
    expect(config?['modelSelection'], {
      'providerId': 'bigmodel-api',
      'modelId': 'glm-5.3',
    });
  });


  testWidgets('无活跃会话也能设置子代理默认模型与思考强度', (tester) async {
    final app = _AgentApp();
    expect(app.conversationStates, isEmpty);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const SubagentsPage()),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('subagent-new')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.enterText(find.byType(TextField).at(0), 'test-agent');
    await tester.enterText(find.byType(TextField).at(1), '测试子代理');
    await tester.enterText(find.byType(TextField).at(2), '完成测试任务');

    // 1.0.9 验收：模型选择=分组弹层（点行开 sheet，按 value 选行）。
    await tester.tap(find.byKey(const ValueKey('editor-model-picker')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey('subagent-model-option-prov-a/glm-test')),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byType(DropdownButtonFormField<String?>).last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('high').last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final channel = app.bridge.channels as _AgentChannel;
    final config = channel.created?['config'] as Map<String, dynamic>?;
    expect(config, isNotNull);
    expect(config?['modelSelection'], {
      'providerId': 'prov-a',
      'modelId': 'glm-test',
      'options': {'reasoningLevel': 'high'},
    });
  });

  test('生产 getView 映射读取嵌套思考档与套餐名', () async {
    final app = _AgentApp();
    final transport = ConversationTransport(
      session: app.bridge,
      scope: const {
        'workspacePath': '/example-workspace',
        'workspaceIdentity': 'ws-agent',
      },
    );
    final options = await transport.modelSelectionOptions();
    expect(options, hasLength(1));
    final value = options.first.options.first;
    expect(value.modelThoughtLevels, ['low', 'high']);
    expect(value.modelProviderName, '个人套餐');
  });
}
