import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/ui/conversation_message_cells.dart';
import 'package:zpocket/ui/turn_model.dart';

/// ④ 提交配置溯源（早前批次）：userInput 行携带 modelSelection/mode/
/// planEnabled 提交快照（官方 rows.ts:119-172，admission 冻结、2026-09-15
/// 起必带）；徽标只在「与上一条带配置的消息相比有已知维度变化」时出现
///（用户拍板）。Highspeed 加速轮/旧消息缺省不参与比较（官方编辑态与
/// 冷恢复同款忽略）。

void main() {
  group('userSubmitConfigOf 解析（官方 userInput 行形态）', () {
    test('完整三项：model+思考档+模式', () {
      final cfg = userSubmitConfigOf(const {
        'kind': 'userInput',
        'text': 'hi',
        'modelSelection': {
          'providerId': 'zai',
          'modelId': 'glm-5.3',
          'options': {'reasoningLevel': 'high'},
        },
        'mode': 'build',
        'planEnabled': false,
      });
      expect(cfg, isNotNull);
      expect(cfg!.identityKey, 'zai/glm-5.3');
      expect(cfg.reasoningLevel, 'high');
      expect(cfg.mode, 'build');
      expect(cfg.planEnabled, false);
    });

    test('Highspeed：官方规则按 providerId 判定（早前批次）', () {
      // 加速卡 Provider（官方 highspeed.ts:21-26 全集）→ null 不参与比较
      //（官方冷恢复 transcript-hydration.ts:1205-1219 同款忽略——加速轮
      // 不更新比较基线，防「加速→原模型」假切换）。
      expect(
        userSubmitConfigOf(const {
          'kind': 'userInput',
          'highspeed': {
            'schemaVersion': 1,
            'cardId': 'c1',
            'taskId': 't1',
            'provider': 'account:zai-highspeed-card',
            'model': 'boost',
            'issuedAt': 1,
            'expiresAt': 2,
          },
          'modelSelection': {
            'providerId': 'account:zai-highspeed-card',
            'modelId': 'boost',
          },
          'mode': 'build',
        }),
        isNull,
      );
      expect(
        userSubmitConfigOf(const {
          'kind': 'userInput',
          'modelSelection': {
            'providerId': 'account:bigmodel-highspeed-card',
            'modelId': 'boost2',
          },
          'mode': 'build',
        }),
        isNull,
      );
      // 队列提升的加速轮：highspeed 元数据在场但 modelSelection 已改回
      // 普通模型（官方 session-flow.ts:126-152）→ 正常参与比较。
      expect(
        userSubmitConfigOf(const {
          'kind': 'userInput',
          'highspeed': {'schemaVersion': 1},
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        }),
        isNotNull,
        reason: '红=旧实现按元数据在场跳过（官方按 providerId——队列加速'
            '轮被错误剔除出比较基线）',
      );
    });

    test('2026-09-15 前旧消息全缺省 → null', () {
      expect(
        userSubmitConfigOf(const {'kind': 'userInput', 'text': '旧'}),
        isNull,
      );
    });

    test('部分缺省（只有 mode）仍是有效配置', () {
      final cfg = userSubmitConfigOf(const {'kind': 'userInput', 'mode': 'plan'});
      expect(cfg, isNotNull);
      expect(cfg!.mode, 'plan');
      expect(cfg.hasModel, isFalse);
    });
  });

  group('userSubmitConfigDiffers：已知维度才判变化', () {
    const base = UserSubmitConfig(
      providerId: 'zai',
      modelId: 'glm-5.3',
      reasoningLevel: 'high',
      mode: 'build',
      planEnabled: false,
    );
    test('完全一致=无变化', () {
      expect(
        userSubmitConfigDiffers(
          base,
          const UserSubmitConfig(
            providerId: 'zai',
            modelId: 'glm-5.3',
            reasoningLevel: 'high',
            mode: 'build',
            planEnabled: false,
          ),
        ),
        isFalse,
      );
    });
    test('模型身份变化', () {
      expect(
        userSubmitConfigDiffers(
          base,
          const UserSubmitConfig(providerId: 'zai', modelId: 'glm-5.3-flash'),
        ),
        isTrue,
      );
    });
    test('思考档变化', () {
      expect(
        userSubmitConfigDiffers(
          base,
          const UserSubmitConfig(
            providerId: 'zai',
            modelId: 'glm-5.3',
            reasoningLevel: 'low',
          ),
        ),
        isTrue,
      );
    });
    test('模式变化（官方无 marker——手机端唯一可见性来源）', () {
      expect(
        userSubmitConfigDiffers(
          base,
          const UserSubmitConfig(
            providerId: 'zai',
            modelId: 'glm-5.3',
            mode: 'yolo',
          ),
        ),
        isTrue,
      );
    });
    test('planEnabled 变化（第一方 Plan 开关形态）', () {
      expect(
        userSubmitConfigDiffers(
          base,
          const UserSubmitConfig(
            providerId: 'zai',
            modelId: 'glm-5.3',
            mode: 'build',
            planEnabled: true,
          ),
        ),
        isTrue,
      );
    });
    test('未知维度不误报（一侧缺省一侧有值）', () {
      // 官方语义：旧消息缺字段按未知处理，不按当前配置补值。
      expect(
        userSubmitConfigDiffers(
          const UserSubmitConfig(mode: 'build'),
          const UserSubmitConfig(
            providerId: 'zai',
            modelId: 'glm-5.3',
            mode: 'build',
          ),
        ),
        isFalse,
        reason: '模型维度一侧未知 → 该维度不判变化',
      );
    });
  });

  group('buildChatItems 徽标判定（窗口内单程比较）', () {
    List<UserItem> usersOf(List<Map<String, dynamic>> rows) =>
        buildChatItems(rows).whereType<UserItem>().toList();

    test('首条=基线不显示；变化点显示；未变化不显示', () {
      final users = usersOf([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '一',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
        {
          'rowId': 2,
          'kind': 'userInput',
          'text': '二',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
        {
          'rowId': 3,
          'kind': 'userInput',
          'text': '三',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'plan',
        },
      ]);
      expect(users.map((u) => u.showConfigBadge), [false, false, true]);
    });

    test('Highspeed 轮跳过：前后同配置不误报切换', () {
      final users = usersOf([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '一',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
        {
          'rowId': 2,
          'kind': 'userInput',
          'text': '加速',
          'highspeed': {'schemaVersion': 1},
          'modelSelection': {
            'providerId': 'account:zai-highspeed-card',
            'modelId': 'boost',
          },
          'mode': 'build',
        },
        {
          'rowId': 3,
          'kind': 'userInput',
          'text': '三',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
      ]);
      // 加速轮自身无徽标（null 配置）；回到原模型也不报「切换」。
      expect(users.map((u) => u.showConfigBadge), [false, false, false]);
    });

    test('旧消息（无配置）夹在新消息之间不破坏基线', () {
      final users = usersOf([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '新',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
        {'rowId': 2, 'kind': 'userInput', 'text': '旧转录（无字段）'},
        {
          'rowId': 3,
          'kind': 'userInput',
          'text': '仍同配置',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
      ]);
      expect(users.map((u) => u.showConfigBadge), [false, false, false]);
    });
  });

  group('guided 行携带配置（官方 guide drain 同投影）', () {
    test('guided userInput 参与变化比较', () {
      final users = buildChatItems(const [
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '一',
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'build',
        },
        {
          'rowId': 2,
          'kind': 'userInput',
          'text': '引导确认',
          'guided': true,
          'modelSelection': {'providerId': 'zai', 'modelId': 'glm-5.3'},
          'mode': 'yolo',
        },
      ]).whereType<UserItem>().toList();
      // guided 行带配置（mode 变化）→ 挂徽标（不因 guided 排除）。
      expect(users.last.showConfigBadge, isTrue,
          reason: '官方 product-projection.ts:4410-4422 guide drain 同走'
              ' userInputSubmittedConfig');
      expect(users.last.submitConfig!.mode, 'yolo');
    });
  });

  group('UserBubble 徽标渲染与文案', () {
    Widget host(Widget child) =>
        MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child));

    testWidgets('变化点渲染徽标；文案=完整配置快照', (tester) async {
      await tester.pumpWidget(
        host(
          const UserBubble(
            text: '这条换了模型',
            submitConfig: UserSubmitConfig(
              providerId: 'zai',
              modelId: 'glm-5.3',
              reasoningLevel: 'high',
              mode: 'build',
              planEnabled: true,
            ),
            showConfigBadge: true,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('user-config-badge')), findsOneWidget);
      // planEnabled=true → 计划模式（第一方桌面形态）。
      expect(find.text('glm-5.3 · 思考高 · 计划模式'), findsOneWidget);
    });

    testWidgets('未变化/无配置零占位', (tester) async {
      await tester.pumpWidget(
        host(
          const UserBubble(
            text: '普通消息',
            submitConfig: UserSubmitConfig(
              providerId: 'zai',
              modelId: 'glm-5.3',
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('user-config-badge')), findsNothing);
    });

      test('badge label：mode 缺省=未知省略；未知枚举原样透传（早前批次）',
        () {
      // 缺省：旧消息未知——不凭空补「默认」。
      expect(
        UserBubble.submitBadgeLabel(
          const UserSubmitConfig(providerId: 'zai', modelId: 'glm-5.3'),
        ),
        'glm-5.3',
        reason: '红=旧实现补「默认」（与「未知维度不硬凑」口径矛盾）',
      );
      // 未知枚举值：原样透传不谎报成任一已知模式。
      expect(
        UserBubble.submitBadgeLabel(
          const UserSubmitConfig(mode: 'auto'),
        ),
        'auto',
      );
    });

  test('badge label：EN 侧官方 label 形态', () {
      // resolvedLocale 缺省非 en-US 时 zh；EN 分支按官方 label 词直查。
      expect(
        submitConfigValueEn['build'],
        'Ask before changes',
      );
      expect(submitConfigValueEn['yolo'], 'Full access');
      // 早前批次：xhigh/edit 用官方 en-US 词（5254/6416）。
      expect(submitConfigValueEn['xhigh'], 'Extra high');
      expect(submitConfigValueEn['edit'], 'Edit automatically');
    });

    testWidgets('EN 渲染：徽标走英文分支（真实渲染路径）', (tester) async {
      L10n.setTestLocale('en-US');
      addTearDown(() => L10n.setTestLocale('zh-CN'));
      await tester.pumpWidget(
        host(
          const UserBubble(
            text: 'model switched message',
            submitConfig: UserSubmitConfig(
              providerId: 'zai',
              modelId: 'glm-5.3',
              reasoningLevel: 'high',
              mode: 'build',
              planEnabled: true,
            ),
            showConfigBadge: true,
          ),
        ),
      );
      expect(find.text('glm-5.3 · High · Plan mode'), findsOneWidget,
          reason: '红=旧实现 EN 分支只测常量、渲染路径从未执行');
    });
  });
}
