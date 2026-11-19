// ③ 会话永久删除（早前批次，PIN 防呆三段流）：
// 范围预览（revision 指纹）→ PIN 闸门（应用锁材料；未设 PIN 引导设置）
// → 执行（blocked/incomplete 人话，不谎报成功）。
// 协议对位：zcode-task previewArchivedTaskDeletion/permanentlyDeleteArchivedTask
//（官方 session-data/contract.ts:54-102 两阶段）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/app_lock.dart'
    show AppLockMode, hashPin, pinMaterialHealthy;
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/ui/session_deletion_flow.dart';

const _salt = '00112233445566778899aabbccddeeff';

Map<String, dynamic> _previewRow({
  String? blockedReason,
  bool incomplete = false,
  bool completed = false,
}) =>
    {
      'sessionId': 'sess-root',
      'revision': 'sha256-abc',
      'sessionIds': const ['sess-root', 'sess-child-sub'],
      'forks': const [
        {'sessionId': 'sess-fork', 'title': '方案分叉'},
      ],
      'retainedArtifacts': const [
        {
          'sessionId': 'sess-root',
          'artifactId': 'art-1',
          'fileName': 'diagram.png',
          'referrers': [
            {'sessionId': 'sess-fork', 'title': '方案分叉'},
          ],
        },
      ],
      'deletedFiles': 8,
      if (blockedReason != null) 'blockedReason': blockedReason,
      'incomplete': incomplete,
      'completed': completed,
    };

class _DelApp extends AppState {
  dynamic previewResult;
  Object? previewError;
  dynamic executeResult;
  Object? executeError;
  final executes = <Map<String, dynamic>>[];

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> previewArchivedTaskDeletion(String taskId) async {
    if (previewError != null) throw previewError!;
    return previewResult;
  }

  @override
  Future<dynamic> permanentlyDeleteArchivedTask(
    String taskId, {
    required String revision,
    required String operationId,
  }) async {
    if (executeError != null) throw executeError!;
    executes.add({
      'taskId': taskId,
      'revision': revision,
      'operationId': operationId,
    });
    return executeResult;
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('entry'),
                onPressed: () => showPermanentDeletionFlow(
                  context,
                  task: const {
                    'taskId': 't-1',
                    'title': '旧任务',
                    'archived': true,
                  },
                ),
                child: const Text('永久删除'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 只推进时间（不得 pumpWidget——会把整棵树换成占位件拆掉在屏弹窗）。
Future<void> _advance(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // UiPrefs.setAppLockMode/Pin 会真写 flutter_secure_storage——
  // testWidgets 假区里真 IO 永不完成（家族）。挂通道 mock
  // 让 write 即时完成（返回 null 即可，字段在 persist 前已置内存）。
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    // system 凭证验证通道（应用锁遮罩同款）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('companion/app_lock'),
      (call) async {
        if (call.method == 'requestSystemUnlock') return true;
        if (call.method == 'isDeviceSecure') return true;
        return null;
      },
    );
  });

  setUp(() {
    // 模块级限流器跨用例存活——每例复位（隔离缝）。
    resetDeletionPinLimiter();
  });

  testWidgets('blocked（running）→ 呈现原因，无确认按钮', (tester) async {
    final app = _DelApp()
      ..previewResult = _previewRow(blockedReason: 'running');
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);

    expect(find.byKey(const ValueKey('perm-del-preview')), findsOneWidget);
    expect(find.textContaining('先停止后再删'), findsOneWidget,
        reason: 'blockedReason 官方词表人话映射');
    expect(find.byKey(const ValueKey('perm-del-confirm')), findsNothing,
        reason: 'blocked 任务不可执行删除——不给出确认入口');
  });

  testWidgets('未设 PIN → 引导去设置（防呆前提：不可恢复操作必须有密码）',
      (tester) async {
    final app = _DelApp()..previewResult = _previewRow();
    // 默认 appLockMode=none → PIN 闸门应拦截。
    expect(app.uiPrefs.appLockModeRaw, 'none');
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    // 范围预览：删什么/留什么可见。
    expect(find.textContaining('2'), findsWidgets);
    expect(find.textContaining('diagram.png'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    expect(find.byKey(const ValueKey('perm-del-pin-missing')), findsOneWidget,
        reason: '红=旧形态无 PIN 闸门（用户拍板：须设置密码后输入密码才可删）');
    expect(app.executes, isEmpty, reason: '未过闸门不得发出 execute');
    // 去设置出口在场。
    expect(
      find.byKey(const ValueKey('perm-del-goto-settings')),
      findsOneWidget,
    );
  });

  testWidgets('PIN 闸门：错 PIN 拦下；正确 PIN → execute 带 revision+operationId',
      (tester) async {
    final app = _DelApp()
      ..previewResult = _previewRow()
      ..executeResult = {'status': 'deleted', 'sessionIds': const []};
    await app.uiPrefs.setAppLockMode('pin');
    await app.uiPrefs.setAppLockPin(_salt, hashPin('1234', _salt));
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    expect(find.byKey(const ValueKey('perm-del-pin-verify')), findsOneWidget);

    // 错 PIN：停留并提示，不执行。
    await tester.enterText(
      find.byKey(const ValueKey('perm-del-pin-input')),
      '9999',
    );
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('PIN 不正确'), findsOneWidget);
    expect(app.executes, isEmpty);

    // 正确 PIN → execute（revision 原样回传+operationId 客户端生成）。
    await tester.enterText(
      find.byKey(const ValueKey('perm-del-pin-input')),
      '1234',
    );
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.executes, hasLength(1));
    expect(app.executes.single['taskId'], 't-1');
    expect(app.executes.single['revision'], 'sha256-abc',
        reason: '两阶段防呆：revision 必须原样回传');
    expect('${app.executes.single['operationId']}', isNotEmpty,
        reason: 'operationId=客户端生成的幂等操作 id');
    expect(find.textContaining('已永久删除'), findsOneWidget);
  });

  testWidgets('execute blocked+changed → 范围变化人话（不谎报成功）',
      (tester) async {
    final app = _DelApp()
      ..previewResult = _previewRow()
      ..executeResult = {
        'status': 'blocked',
        'reason': 'changed',
        'sessionIds': const [],
      };
    await app.uiPrefs.setAppLockMode('pin');
    await app.uiPrefs.setAppLockPin(_salt, hashPin('1234', _salt));
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    await tester.enterText(
      find.byKey(const ValueKey('perm-del-pin-input')),
      '1234',
    );
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('请重新预览'), findsOneWidget);
    expect(find.textContaining('已永久删除'), findsNothing);
  });

  testWidgets('completed（幂等已删）→ 明示已删透，无确认入口', (tester) async {
    final app = _DelApp()..previewResult = _previewRow(completed: true);
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    expect(find.textContaining('已被彻底删除'), findsOneWidget);
    expect(find.byKey(const ValueKey('perm-del-confirm')), findsNothing);
  });

  testWidgets('system 模式：系统凭证通过即执行（不出 PIN 框）',
      (tester) async {
    final app = _DelApp()
      ..previewResult = _previewRow()
      ..executeResult = {'status': 'deleted', 'sessionIds': const []};
    await app.uiPrefs.setAppLockMode('system');
    // 控制器模式装载（真实 app 由 AppLockGate 首帧完成；闸门读控制器）。
    app.appLock.loadFromPrefs(
      mode: AppLockMode.system,
      autoLockSeconds: 60,
      secureFlagPref: false,
    );
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    // system 模式确认钮文案=系统验证。
    expect(find.text('继续（需系统验证）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    // 系统凭证（mock true）通过 → 直接执行，无 PIN 对话框。
    expect(find.byKey(const ValueKey('perm-del-pin-verify')), findsNothing);
    expect(app.executes, hasLength(1),
        reason: '红=旧实现 system 用户被引导去设置（强制降级锁方式）');
    expect(find.textContaining('已永久删除'), findsOneWidget);
  });

  testWidgets('execute 返回 null（桥断开）→「结果未知」不谎报 incomplete',
      (tester) async {
    final app = _DelApp()
      ..previewResult = _previewRow()
      ..executeResult = null;
    await app.uiPrefs.setAppLockMode('pin');
    await app.uiPrefs.setAppLockPin(_salt, hashPin('1234', _salt));
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    await tester.enterText(
      find.byKey(const ValueKey('perm-del-pin-input')),
      '1234',
    );
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
    await _advance(tester);
    expect(find.textContaining('删除结果未知'), findsOneWidget,
        reason: '红=旧实现把 null 归入 incomplete 谎报「部分数据已清理」');
    expect(find.textContaining('部分数据已清理'), findsNothing);
  });

  testWidgets('execute incomplete → 独立人话（可续删提示）', (tester) async {
    final app = _DelApp()
      ..previewResult = _previewRow()
      ..executeResult = {'status': 'incomplete', 'sessionIds': const []};
    await app.uiPrefs.setAppLockMode('pin');
    await app.uiPrefs.setAppLockPin(_salt, hashPin('1234', _salt));
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    await tester.enterText(
      find.byKey(const ValueKey('perm-del-pin-input')),
      '1234',
    );
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
    await _advance(tester);
    expect(find.textContaining('删除未完成'), findsOneWidget);
    expect(find.textContaining('已永久删除'), findsNothing);
  });

  testWidgets('PIN 冷却跨对话框存活：5 错 → 取消重开 → 仍在冷却',
      (tester) async {
    final app = _DelApp()..previewResult = _previewRow();
    await app.uiPrefs.setAppLockMode('pin');
    await app.uiPrefs.setAppLockPin(_salt, hashPin('1234', _salt));
    await _pump(tester, _host(app));

    Future<void> openToPin() async {
      await tester.tap(find.byKey(const ValueKey('entry')));
      await _advance(tester);
      await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
      await _advance(tester);
    }

    // 第一轮：错 5 次（第 5 次触发 30s 冷却文案）。
    await openToPin();
    for (var i = 0; i < 5; i++) {
      await tester.enterText(
        find.byKey(const ValueKey('perm-del-pin-input')),
        '9999',
      );
      await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('尝试过多'), findsOneWidget);
    // 取消 → 重开流（新对话框）。
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-cancel')));
    await _advance(tester);
    await openToPin();
    // 再错一次：立即冷却提示（计数未因重开清零）。
    await tester.enterText(
      find.byKey(const ValueKey('perm-del-pin-input')),
      '9999',
    );
    await tester.tap(find.byKey(const ValueKey('perm-del-pin-ok')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('尝试过多'), findsOneWidget,
        reason: '红=旧实现 limiter 每对话框实例化（取消重开即清零）');
    expect(app.executes, isEmpty);
  });

  testWidgets('pin 材料损坏（盐奇数长度）→ 走引导不出 PIN 框',
      (tester) async {
    final app = _DelApp()..previewResult = _previewRow();
    await app.uiPrefs.setAppLockMode('pin');
    await app.uiPrefs.setAppLockPin('abc', hashPin('1234', 'abc'));
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    await tester.tap(find.byKey(const ValueKey('perm-del-confirm')));
    await _advance(tester);
    // 材料=mode pin 但盐非法 → 引导对话框（不是 PIN 框、不 hashPin 崩）。
    expect(find.byKey(const ValueKey('perm-del-pin-missing')), findsOneWidget);
    expect(find.byKey(const ValueKey('perm-del-pin-verify')), findsNothing);
    expect(app.executes, isEmpty);
  });

  testWidgets('preview 缺 revision → 无确认按钮（不进闸门）', (tester) async {
    final app = _DelApp()
      ..previewResult = {
        'sessionId': 'sess-root',
        'sessionIds': const ['sess-root'],
        'deletedFiles': 3,
      };
    await _pump(tester, _host(app));

    await tester.tap(find.byKey(const ValueKey('entry')));
    await _advance(tester);
    expect(find.byKey(const ValueKey('perm-del-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('perm-del-confirm')), findsNothing,
        reason: 'revision 缺失=宿主形态异常，不得进入执行');
  });

  test('pinMaterialHealthy：缺失/垃圾判定', () {
    expect(pinMaterialHealthy(null, null), isFalse);
    expect(pinMaterialHealthy('', ''), isFalse);
    expect(pinMaterialHealthy('abc', 'a'.padRight(64, 'a')), isFalse,
        reason: '盐奇数长度=hashPin 会抛');
    expect(pinMaterialHealthy('zz' * 16, 'a'.padRight(64, 'a')), isFalse,
        reason: '非 hex 盐');
    expect(pinMaterialHealthy('00' * 16, 'ab' * 32), isTrue);
  });

  test('blockedReason 词表人话映射', () {
    expect(deletionBlockedReasonText('running'), contains('停止'));
    expect(deletionBlockedReasonText('not-archived'), contains('归档'));
    expect(deletionBlockedReasonText('weird'), contains('weird'),
        reason: '未知原因透传不吞');
  });

}
