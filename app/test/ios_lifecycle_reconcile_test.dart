// iOS 生命周期语义回归（早前批次 对抗审查发现+）：
//
// 挂起期对账水位——无保活平台（iOS）退后台走 90s 断连 Timer，但
// 进程挂起后 Dart 定时器冻结：Timer 从不触发，回前台 onAppResumed 又先
// 取消它 → notifyCoordinator.onSuspended 的对账水位从未记录，隔夜
// 完成/审批事件回前台全丢（杀进程冷启动反而恢复——冷启动走全新快照）。
// 修=退后台记墙钟戳；回前台若 Timer 未触发而墙钟已过窗，就地补水位并
// 推进悬挂态走前台重连路径（等价于「Timer 在冻结中触发、效应解冻落地」）。
//
// 假开关——无保活平台的「审批提醒」开关即通知总开关（
// iOS 语义），关=全部静音；此前关了仍照发。Android 有 FGS 语义分层
// 不受此门控（零变化断言钉死）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/notify/notification_service.dart';
import 'package:zpocket/state/account_store.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/computer_stack.dart';
import 'package:zpocket/state/notify_coordinator.dart';
import 'package:zpocket/state/notify_core.dart';
import 'package:zpocket/state/notify_store.dart';
import 'package:zpocket/state/profile_store.dart';
import 'package:zpocket/transport/z_transport.dart'
    show AccountV2Profile, DeviceProfile;

AccountV2Profile _v2(String sid) => AccountV2Profile(
  deviceSid: sid,
  accountId: 'acc-1',
  label: '电脑-$sid',
  addedAt: DateTime(2026),
);

class _ProbeStack extends ComputerStack {
  _ProbeStack(String sid)
    : super(
        profile: _v2(sid),
        onLog: (_) {},
        onFailure: (_, _) {},
      );

  LinkPhase status = LinkPhase.online;
  int pokeOrResumeCalls = 0;

  @override
  LinkPhase computeStatus() => status;

  @override
  Future<void> pokeOrResume() async {
    pokeOrResumeCalls++;
  }

  @override
  Future<void> resumeTasksIndexFromBackground() async {}

  @override
  Future<void> demote() async {}

  @override
  Future<void> disposeStack() async {}

  @override
  void reportViewState({String? taskId}) {}
}

class _MemNotifyStore extends NotifyStore {
  _MemNotifyStore(super.baseDir);

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> markClicked(String taskId, int atMs) async {}
}

class _NullBackend implements NotificationBackend {
  _NullBackend({this.checkResult});

  /// 测试缝：null=查询不可用（默认），true/false=系统权限现状。
  final bool? checkResult;

  @override
  Future<bool> initialize() async => true;

  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool?> checkPermission() async => checkResult;

  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload, {
    List<NotifyNotificationAction> actions = const [],
  }) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async => const [];

  @override
  Future<String?> launchPayload() async => null;
}

class _FakeNotifyService extends NotificationService {
  // ignore: unused_element_parameter
  _FakeNotifyService({this.permissionGranted = true, bool? backendPermission})
    : super(backend: _NullBackend(checkResult: backendPermission));

  final bool permissionGranted;

  @override
  Future<bool> ensurePermission() async => permissionGranted;
}

class _MemoryProfiles extends ProfileStore {
  _MemoryProfiles(this.items);

  List<DeviceProfile> items;
  String? active;

  @override
  Future<({List<DeviceProfile> profiles, int skipped})>
  listProfilesDetailed() async => (profiles: List.of(items), skipped: 0);

  @override
  Future<DeviceProfile> upsertProfile(DeviceProfile profile) async {
    items = [
      for (final p in items)
        if (p.deviceSid != profile.deviceSid) p,
      profile,
    ];
    return profile;
  }

  @override
  Future<void> updateProfile(DeviceProfile profile) async {}

  @override
  Future<String?> activeDeviceSid() async => active;

  @override
  Future<void> setActiveDeviceSid(String? deviceSid) async {
    active = deviceSid;
  }
}

class _FakeAccountStore extends AccountStore {
  @override
  Future<List<StoredAccount>> listAccounts() async => const [];

  @override
  Future<String?> get lastUsedAccountId async => null;

  @override
  Future<String?> get mostRecentAccountId async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const notifyChannel = MethodChannel('companion/notify');

  Future<void> mockFgs() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, (call) async => null);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, null);
  });

  group('H3 挂起期对账水位（iOS 冻结补偿）', () {
    // 平台覆写在体内 try/finally 复位（不变量检查早于 tearDown 的教训）。

    test('挂起一晚回前台：Timer 冻结未触发 → 补记水位+走重连路径', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mockFgs();
        final tmp = await Directory.systemTemp.createTemp('h3-frozen');
        addTearDown(() => tmp.delete(recursive: true));
        final app = AppState();
        final stack = _ProbeStack('sid-frozen');
        app.debugRegisterStackForTest(stack);
        final coordinator = NotifyCoordinator(
          store: _MemNotifyStore(tmp),
          onPost: (_) async => false,
        );
        app.notifyCoordinator = coordinator;
        coordinator.attachStack(stack);
        addTearDown(app.dispose);
        await app.activate(stack.profile);

        // 墙钟注入：pause=T0；不推进任何虚拟时间（真实形态=定时器随进程
        // 冻结，90s 从未走完）→ 回前台时钟已过一晚。
        var now = DateTime(2026, 11, 15, 8);
        final pokeBaseline = stack.pokeOrResumeCalls;
        app.debugLifecycleClock = () => now;
        app.onAppPaused();
        now = now.add(const Duration(hours: 14));

        app.onAppResumed();

        // 红：修复前水位恒空——onSuspended 永不被调（Timer 冻结+回前台
        // 先取消），隔夜事件回前台全丢。
        expect(
          coordinator.debugPendingReconcile.containsKey('sid-frozen'),
          isTrue,
          reason: '冻结补偿：挂起过窗后回前台必须补记对账水位',
        );
        expect(
          stack.pokeOrResumeCalls - pokeBaseline,
          1,
          reason: '补偿推进悬挂态 → 走前台重连路径（pokeOrResume，基线外恰一次）',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('快速往返（<90s）：不补偿——水位不写、不推进悬挂', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mockFgs();
        final tmp = await Directory.systemTemp.createTemp('h3-quick');
        addTearDown(() => tmp.delete(recursive: true));
        final app = AppState();
        final stack = _ProbeStack('sid-quick');
        app.debugRegisterStackForTest(stack);
        final coordinator = NotifyCoordinator(
          store: _MemNotifyStore(tmp),
          onPost: (_) async => false,
        );
        app.notifyCoordinator = coordinator;
        coordinator.attachStack(stack);
        addTearDown(app.dispose);
        await app.activate(stack.profile);

        final pokeBaseline = stack.pokeOrResumeCalls;
        var now = DateTime(2026, 11, 15, 8);
        app.debugLifecycleClock = () => now;
        app.onAppPaused();
        now = now.add(const Duration(seconds: 10));

        app.onAppResumed();

        expect(
          coordinator.debugPendingReconcile,
          isEmpty,
          reason: '短于断连窗的正常往返不补偿（不吞实时通知）',
        );
        expect(stack.pokeOrResumeCalls - pokeBaseline, 0, reason: '未过窗不推进悬挂态');
        expect(app.suspendedAll, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('iOS 假开关（审批提醒=通知总开关）', () {
    test('iOS 关：三通道全静音；开启后放行', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mockFgs();
        final tmp = await Directory.systemTemp.createTemp('mute-ios');
        addTearDown(() => tmp.delete(recursive: true));
        final app = AppState(
          store: _MemoryProfiles(const []),
          notifyService: _FakeNotifyService(),
          notifyStore: _MemNotifyStore(tmp),
          accountStore: _FakeAccountStore(),
        );
        addTearDown(app.dispose);

        await app.load();

        // 默认 alertsEnabled=false：iOS 全静音（红：修复前静音集合只看
        // 三个分通道开关，总开关关了仍照发）。
        expect(
          app.notifyCoordinator!.mutedChannels,
          containsAll([
            NotifyChannel.approvals,
            NotifyChannel.tasks,
            NotifyChannel.goals,
          ]),
          reason: 'iOS 无保活：审批提醒关=通知总开关关',
        );

        await app.setAlertsEnabled(true);
        expect(
          app.notifyCoordinator!.mutedChannels,
          isEmpty,
          reason: '总开关开（权限桩通过）→ 三通道放行',
        );

        await app.setAlertsEnabled(false);
        expect(
          app.notifyCoordinator!.mutedChannels,
          containsAll(NotifyChannel.values),
          reason: '再次关闭恢复全静音（uiPrefs 监听即时生效）',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('Android 关：零变化——总开关不进静音集合', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await mockFgs();
        final tmp = await Directory.systemTemp.createTemp('mute-android');
        addTearDown(() => tmp.delete(recursive: true));
        final app = AppState(
          store: _MemoryProfiles(const []),
          notifyService: _FakeNotifyService(),
          notifyStore: _MemNotifyStore(tmp),
          accountStore: _FakeAccountStore(),
        );
        addTearDown(app.dispose);

        await app.load();

        // Android 语义分层：alertsEnabled 只管 FGS 保活，不静音前台通知
        // （零回归断言）。
        expect(app.notifyCoordinator!.mutedChannels, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('冷启动权限复查', () {
    test('系统权限已关 → 开关回弹+人话提示+不启动 FGS', () async {
      await mockFgs();
      final tmp = await Directory.systemTemp.createTemp('perm-recheck');
      addTearDown(() => tmp.delete(recursive: true));
      final app = AppState(
        store: _MemoryProfiles(const []),
        notifyService: _FakeNotifyService(backendPermission: false),
        notifyStore: _MemNotifyStore(tmp),
        accountStore: _FakeAccountStore(),
      );
      addTearDown(app.dispose);
      // 模拟「上次会话开着」的持久化态（绕过开关路径的权限门）。
      await app.uiPrefs.setAlertsEnabled(true);

      await app.load();

      // 红：修复前 load 只查 FGS（iOS no-op 成功）——开关显示开、通知
      // 被系统静默丢弃无感知。
      expect(app.uiPrefs.alertsEnabled, isFalse, reason: '权限已关则回弹');
      expect(app.alertsError, isNotNull, reason: '置人话提示');
    });

    test('权限在场（true/null）→ 维持开启照常启动', () async {
      await mockFgs();
      final tmp = await Directory.systemTemp.createTemp('perm-ok');
      addTearDown(() => tmp.delete(recursive: true));
      final app = AppState(
        store: _MemoryProfiles(const []),
        notifyService: _FakeNotifyService(backendPermission: true),
        notifyStore: _MemNotifyStore(tmp),
        accountStore: _FakeAccountStore(),
      );
      addTearDown(app.dispose);
      await app.uiPrefs.setAlertsEnabled(true);

      await app.load();

      expect(app.uiPrefs.alertsEnabled, isTrue, reason: '权限在场不回弹');
      expect(app.alertsError, isNull);
    });
  });
}
