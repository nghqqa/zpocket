// 任务完成横幅（orientation-unlock-1，vivo 真机反馈「完成只有震动+
// 锁屏内容、无顶部横幅」）红绿：
// - 渠道档：默认关=tasks（default importance，「完成不打断」2026-10-20
//   拍板不变）；开=tasks_alert 高优渠道；审批/Goal 不受开关影响；
// - UiPrefs 持久化往返；
// - 设置页开关：Android 可见可切换、iOS 隐藏（无渠道概念不撒谎）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/notify/notification_service.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/state/notify_core.dart';
import 'package:zpocket/state/ui_prefs.dart';
import 'package:zpocket/ui/settings_notifications_page.dart';

class _ChanBackend implements NotificationBackend {
  final channels = <String>[];
  final active = <NotifyActiveEntry>[];
  final cancelled = <int>[];

  @override
  Future<bool> initialize() async => true;
  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<bool?> checkPermission() async => null;
  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload, {
    List<NotifyNotificationAction> actions = const [],
  }) async {
    channels.add(channel);
  }
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
  @override
  Future<void> cancelAll() async {}
  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async => active;
  @override
  Future<String?> launchPayload() async => null;
}

class _MemStorage extends FlutterSecureStorage {
  final data = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
  }
}

class _NotifApp extends AppState {
  _NotifApp(this.prefs);
  final UiPrefs prefs;
  @override
  UiPrefs get uiPrefs => prefs;
}

NotifyEvent _taskDone() => NotifyEvent(
      channel: NotifyChannel.tasks,
      kind: NotifyEventKind.taskCompleted,
      deviceSid: 'sid',
      taskId: 'task-1',
      title: '示例任务',
      atMs: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('渠道档（post → backend.show 的 channel）', () {
    test('默认关：任务完成走 tasks 渠道（「完成不打断」不变）', () async {
      final backend = _ChanBackend();
      final service = NotificationService(backend: backend);
      await service.init();
      expect(await service.post(_taskDone()), isTrue);
      expect(backend.channels, const [NotificationService.channelTasks]);
    });

    test('开启：任务完成走 tasks_alert 高优渠道', () async {
      final backend = _ChanBackend();
      final service = NotificationService(backend: backend);
      service.taskHeadsUpResolver = () => true;
      await service.init();
      expect(await service.post(_taskDone()), isTrue);
      expect(backend.channels, const [NotificationService.channelTasksAlert]);
    });

    test('开关不影响审批与 Goal 渠道', () async {
      final backend = _ChanBackend();
      final service = NotificationService(backend: backend);
      service.taskHeadsUpResolver = () => true;
      await service.init();
      expect(
        await service.post(const NotifyEvent(
          channel: NotifyChannel.approvals,
          kind: NotifyEventKind.approvalPending,
          deviceSid: 'sid',
          taskId: 'task-2',
          title: '示例审批',
          atMs: 0,
        )),
        isTrue,
      );
      expect(
        await service.post(const NotifyEvent(
          channel: NotifyChannel.goals,
          kind: NotifyEventKind.goalSettled,
          deviceSid: 'sid',
          taskId: 'task-3',
          title: '示例目标',
          atMs: 0,
        )),
        isTrue,
      );
      expect(backend.channels, const [
        NotificationService.channelApprovals,
        NotificationService.channelGoals,
      ]);
    });

    test('冷启动在栏判定：tasks_alert 归属 tasks 通道（同通道清理语义）',
        () async {
      expect(
        NotificationService.channelTasksAlert ==
                NotificationService.channelTasks,
        isFalse,
        reason: '渠道 id 不同（Android importance 创建即固化，升档须换新渠道）',
      );
    });
  });

  group('UiPrefs 持久化', () {
    test('taskHeadsUp 默认关；setTaskHeadsUp 落盘并往返', () async {
      final storage = _MemStorage();
      final prefs = UiPrefs(storage: storage);
      await prefs.load();
      expect(prefs.taskHeadsUp, isFalse, reason: '默认关=原语义零变化');

      await prefs.setTaskHeadsUp(true);
      expect(prefs.taskHeadsUp, isTrue);

      final reloaded = UiPrefs(storage: storage);
      await reloaded.load();
      expect(reloaded.taskHeadsUp, isTrue, reason: '重启保持');

      await prefs.setTaskHeadsUp(false);
      expect(prefs.taskHeadsUp, isFalse);
      expect(storage.data['ui.taskHeadsUp'], 'false');
    });
  });

  group('通知设置页开关', () {
    // widget 测试默认 android（capabilities 判定基准）。
    testWidgets('Android：开关可见，点按即生效并落盘', (tester) async {
      final prefs = UiPrefs(storage: _MemStorage());
      await prefs.load();
      await tester.pumpWidget(
        AppStateScope(
          app: _NotifApp(prefs),
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const SettingsNotificationsPage(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('任务完成横幅'), findsOneWidget);
      final tile = find.widgetWithText(SwitchListTile, '任务完成横幅');
      expect(tile, findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(tile).value,
        isFalse,
        reason: '默认关',
      );

      await tester.tap(tile);
      await tester.pump();
      expect(prefs.taskHeadsUp, isTrue, reason: '点按即生效');
    });

    testWidgets('iOS：入口隐藏（无渠道 importance 概念，UI 不撒谎）',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final prefs = UiPrefs(storage: _MemStorage());
      await prefs.load();
      await tester.pumpWidget(
        AppStateScope(
          app: _NotifApp(prefs),
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const SettingsNotificationsPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('任务完成横幅'), findsNothing);
      // 帧检定前复位（_verifyInvariants 断言 foundation 调试变量全空）。
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
