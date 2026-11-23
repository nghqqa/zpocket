import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../state/notify_core.dart';
import '../core/l10n.dart';

/// 安卓通知后端缝（生产 flutter_local_notifications / 测试 Fake）。
abstract class NotificationBackend {
  Future<bool> initialize();

  /// 热点击回调接线（生产后端把插件的回调转发到这里）。
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}
  Future<bool> requestPermission();

  /// 系统通知权限现状（true=有权限 / false=无 / null=查询不可用）。
  ///
  /// 与 [initialize]/[requestPermission] 分工（早前批次）：
  /// initialize 只回答「后端可调用」（iOS 恒 true 的就绪语义，见生产
  /// 实现），requestPermission 会弹系统授权框；本方法只读查询，供冷
  /// 启动复查——用户先在系统设置关掉通知后，开关不应仍显示为开、发
  /// 通知静默失败。null=平台通道未就绪或查询异常，调用方据此不改开
  /// 关态（宁可维持现状，不误翻开关）。
  Future<bool?> checkPermission() async => null;

  Future<void> show(int id, String title, String body, String channel, String payload,
      {List<NotifyNotificationAction> actions = const []});
  Future<void> cancel(int id);

  /// 清全部（保留给后端/诊断；启动清理改走 [activeNotifications] +
  /// [cancel] 的选择性路径——审批条目不能在冷启动被误清）。
  Future<void> cancelAll() async {}

  /// 通知栏现存条目（冷启动选择性清理输入）。不支持/查询失败时返回
  /// 空——调用方据此不清扫（宁可让 tasks/goals 条目按 timeoutAfter
  /// 自然过期，也不误杀仍在等待的审批）。
  Future<List<NotifyActiveEntry>> activeNotifications() async => const [];

  /// 冷启动来源（app 由通知点开启动时的 payload；无=null）。
  Future<String?> launchPayload() async => null;
}

/// 通知栏现存条目（id + 通道）。
class NotifyActiveEntry {
  final int id;
  final String? channelId;

  /// 点击路由 payload（接管簿用：冷启动时按它把遗留审批条目还原
  /// 进本进程 _active/_idsByTask）。
  final String? payload;
  const NotifyActiveEntry({required this.id, this.channelId, this.payload});
}

/// 点击路由 payload（不塞完整对象，sid+taskId 反查——设计文档约定）。
class NotifyTapPayload {
  final String deviceSid;
  final String taskId;
  final String kind; // NotifyEventKind.name

  /// 通知产生时刻（事件 atMs）——两步式深链用它定位「产生通知的那条
  /// 消息」（2026-11-04 用户拍板：打开会话后弹短暂浮层，用户确认再定位）。
  final int atMs;

  /// 审批事件的 interactionId（2026-11-14 快捷审批批：通知动作按钮
  /// 凭它与 session 直接 resolve；旧 payload 无此键=decode 出 null）。
  final String? interactionId;
  const NotifyTapPayload(this.deviceSid, this.taskId, this.kind,
      {this.atMs = 0, this.interactionId});

  String encode() => jsonEncode({
        'sid': deviceSid,
        'task': taskId,
        'kind': kind,
        'at': atMs,
        if (interactionId != null) 'iid': interactionId,
      });

  static NotifyTapPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final sid = '${map['sid'] ?? ''}';
      final task = '${map['task'] ?? ''}';
      if (sid.isEmpty || task.isEmpty) return null;
      return NotifyTapPayload(
        sid,
        task,
        '${map['kind'] ?? ''}',
        atMs: (map['at'] as num?)?.toInt() ?? 0,
        interactionId: map['iid'] == null ? null : '${map['iid']}',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 审批快捷动作按钮（通知栏直接批准/拒绝）：id=语义选择（accept/
/// decline），payload=完整审批意图 JSON（主 isolate 消费用）。
class NotifyNotificationAction {
  final String id;
  final String title;
  final String payload;
  const NotifyNotificationAction(this.id, this.title, this.payload);
}

/// 审批快捷动作意图的落盘键（后台 isolate 写 → 主 isolate 轮询消费）。
const approvalActionIntentKey = 'notify.approvalActionIntent';
const _approvalActionChoiceAccept = 'accept';
const _approvalActionChoiceDecline = 'decline';

/// 后台 isolate 动作回调（插件约定：顶层函数 + vm:entry-point）。
/// 只落盘审批意图 + 受理反馈——真正的审批执行在主 isolate 轮询
/// 消费（活连接在那边）。DartPluginRegistrant 确保后台引擎里
/// 插件通道（secure storage 等）可用。
@pragma('vm:entry-point')
Future<void> notificationActionBackgroundHandler(NotificationResponse response) async {
  DartPluginRegistrant.ensureInitialized();
  final choice = response.actionId ?? '';
  if (choice != _approvalActionChoiceAccept && choice != _approvalActionChoiceDecline) {
    return;
  }
  final intent = response.payload ?? '';
  if (intent.isEmpty) return;
  try {
    const storage = FlutterSecureStorage();
    await storage.write(
      key: approvalActionIntentKey,
      value: jsonEncode({
        'choice': choice,
        'intent': intent,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    // 受理反馈：换一条 4 秒确认条（原审批通知随 autoCancel 已移除）。
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.show(
      id: response.id ?? DateTime.now().millisecondsSinceEpoch % 100000,
      title: choice == _approvalActionChoiceAccept ? '已提交批准' : '已提交拒绝',
      body: '打开应用后自动完成',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'approvals', '审批提醒',
          icon: 'ic_notification',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          timeoutAfter: 4000,
        ),
      ),
    );
  } catch (_) {}
}

/// 通知服务（三通道 + 点击路由 + 回前台清过时）。
///
/// 通道常量与点击 payload 在本文件一处定义（设计文档约定）；
/// 台账与差分在协调器（notify_coordinator.dart），本类只管安卓侧。
class NotificationService {
  NotificationService({required this.backend});

  final NotificationBackend backend;

  static const channelApprovals = 'approvals'; // 审批：高优先级 heads-up
  static const channelTasks = 'tasks'; // 完成/失败
  static const channelGoals = 'goals'; // Goal 里程碑

  /// 任务完成横幅渠道（orientation-unlock-1 批）：tasks 的可切换高优
  /// 档——Android 8+ 渠道 importance 创建即固化、代码不可升级，升档
  /// 必须换新渠道 id（旧 tasks 渠道残留一条死记录，无害）。归属仍为
  /// NotifyChannel.tasks（清理/台账逻辑同通道对待）。
  static const channelTasksAlert = 'tasks_alert';

  /// 任务完成横幅开关读取（默认关）。由 AppState 接线到 uiPrefs；
  /// 测试注入。null/不设=关。
  bool Function()? taskHeadsUpResolver;

  /// 遗留通知通道判定（早前批次）。channelId 路=Android 8+；
  /// kind 路=iOS 回退（payload 的 NotifyEventKind.name → 通道归属，
  /// 与 notify_core 事件→通道归属同源）。
  static NotifyChannel? _channelFromId(String id) => switch (id) {
        channelTasks || channelTasksAlert => NotifyChannel.tasks,
        channelGoals => NotifyChannel.goals,
        channelApprovals => NotifyChannel.approvals,
        _ => null,
      };

  static NotifyChannel? _channelFromKind(String? kind) => switch (kind) {
        'approvalPending' => NotifyChannel.approvals,
        'goalSettled' || 'goalVerifying' => NotifyChannel.goals,
        'taskCompleted' || 'taskFailed' || 'awayAggregated' =>
          NotifyChannel.tasks,
        _ => null,
      };

  String channelOf(NotifyChannel c) => switch (c) {
    NotifyChannel.approvals => channelApprovals,
    NotifyChannel.tasks => channelTasks,
    NotifyChannel.goals => channelGoals,
  };

  bool _ready = false;
  bool get ready => _ready;

  /// 冷启动点击 payload（init 时尚未接线 onTap——由 AppState 挂好
  /// 路由后 consumePendingLaunch 取走，微任务时序吞 payload 的修法，
  /// 发现2b）。
  NotifyTapPayload? _pendingLaunch;

  /// 活跃通知簿（清过时用）：id → (taskId, channel)。
  final Map<int, (String, NotifyChannel)> _active = {};
  Map<int, (String, String)> get activeForTest => {
    for (final e in _active.entries) e.key: (e.value.$1, e.value.$2.name),
  };

  /// 点击路由回调（协调器注入：activate 栈 → 打开会话页）。
  void Function(NotifyTapPayload payload)? onTap;

  /// 初始化 + 冷启动点击 payload 暂存 + 孤儿通知清理。
  Future<void> init({String? launchPayload}) async {
    try {
      _ready = await backend.initialize();
    } catch (_) {
      _ready = false;
    }
    // 热点击接线：后端回调 → handleTap（此前生产后端自己的 onTap 字段
    // 无人赋值，点击只在通知层空转——发现2a）。
    backend.setTapHandler(handleTap);
    // 上一进程遗留的通知栏孤儿（本进程 _active 为空清不到）：只清
    // 本 app 的任务/目标通道——审批条目保留（冷启动差分不会补发仍在
    // 等待的审批，全清=审批提醒永久丢失，状态层批）。查询不到在栏
    // 列表时不清扫（tasks/goals 有 timeoutAfter 自然过期兜底）。
    try {
      final active = await backend.activeNotifications();
      for (final n in active) {
        // （复审）②：_nextId 先越过**全部**遗留 id（含将被清除的
        // tasks/goals）——避免新通知按 id 覆盖任何在栏条目。
        if (n.id >= _nextId) _nextId = n.id + 1;
        // 通道判定双路（早前批次）：channelId 仅 Android 8+
        // 返回（插件 types.dart:74-77「Returned only on Android」）——
        // iOS 按遗留条目 payload 的 kind 回退（与 post 时的
        // kind→channel 归属同源）。
        final ch = n.channelId != null
            ? _channelFromId(n.channelId!)
            : _channelFromKind(NotifyTapPayload.decode(n.payload)?.kind);
        if (ch == NotifyChannel.tasks || ch == NotifyChannel.goals) {
          await backend.cancel(n.id);
          continue;
        }
        // （复审）①：遗留审批条目接管进本进程簿——clearStale 从此
        // 清得掉（审批不过期）。
        if (ch == NotifyChannel.approvals) {
          final pl = NotifyTapPayload.decode(n.payload);
          if (pl != null) {
            _active[n.id] = (pl.taskId, NotifyChannel.approvals);
            _idsByTask['${NotifyChannel.approvals.name}:${pl.taskId}'] = n.id;
          }
        }
      }
    } catch (_) {}
    final raw = launchPayload ?? await backend.launchPayload();
    _pendingLaunch = NotifyTapPayload.decode(raw);
  }

  /// 冷启动点击路由（AppState 挂好 onTap 后调用一次；消费后置空）。
  NotifyTapPayload? consumePendingLaunch() {
    final p = _pendingLaunch;
    _pendingLaunch = null;
    return p;
  }

  Future<bool> ensurePermission() async {
    try {
      return await backend.requestPermission();
    } catch (_) {
      return false;
    }
  }

  /// 事件 id 起点避开前台服务常驻通知 id（ForegroundService.kt 用 100）
  /// ——从 1 起编时第 100 条任务通知会覆盖/顶掉常驻状态通知。
  int _nextId = 1000;
  final Map<String, int> _idsByTask = {};

  /// 截断点避开 UTF-16 代理对（emoji）中间——
  /// 孤立代理项经平台通道 UTF-8 编码成 U+FFFD 显示为乱码。
  static String _cutAtCodePoint(String s, int limit) {
    if (limit < s.length && (s.codeUnitAt(limit) & 0xFC00) == 0xDC00) {
      return s.substring(0, limit - 1);
    }
    return s.substring(0, limit);
  }

  /// 事件 id：同任务同通道复用（新事件覆盖旧通知，不堆叠）。
  int _idOf(NotifyEvent e) =>
      _idsByTask.putIfAbsent('${e.channel.name}:${e.taskId}', () => _nextId++);

  Future<bool> post(NotifyEvent e, {String? deviceLabel}) async {
    if (!_ready) return false;
    final id = _idOf(e);
    final label = (deviceLabel == null || deviceLabel.isEmpty) ? '' : '$deviceLabel · ';
    final String title;
    switch (e.kind) {
      case NotifyEventKind.taskCompleted:
        title = '$label${tr('任务完成')}';
      case NotifyEventKind.taskFailed:
        title = '$label${tr('任务失败')}';
      case NotifyEventKind.approvalPending:
        title = '$label${e.detail == 'userInput' ? tr('等你输入') : tr('等你审批')}';
      case NotifyEventKind.goalSettled:
        // （2026-10-24 修复批）：三值细分（官方 snapshot.ts:427-428
        // ——notSatisfied=有效结论未达成；failed=验证过程失败）。
        title = '$label${switch (e.detail) {
          'verified' => tr('目标达成'),
          'failed' => tr('目标验证失败'),
          _ => tr('目标未达成'),
        }}';
      case NotifyEventKind.goalVerifying:
        title = '$label${tr('目标验证中')}';
      case NotifyEventKind.awayAggregated:
        // 聚合通知也带设备名（多电脑区分谁完成了任务）。
        title = '$label${tr('你不在时完成了 ${e.detail} 个任务')}';
    }
    // 正文打磨：完成/失败带最后回复预览（比标题更贴近"完成了
    // 什么"，缺省回退标题）；审批带轻量工具名（si 透传，不带问题等
    // 敏感 payload）；聚合保持引导点击。
    final String body;
    if (e.kind == NotifyEventKind.awayAggregated) {
      // 聚合点击实际直达 sampleTask 会话页（非任务
      // 列表）——文案与行为对齐。
      body = tr('点按查看任务');
    } else if (e.kind == NotifyEventKind.approvalPending) {
      final tool = (e.tool ?? '').trim();
      body = tool.isEmpty
          ? (e.title.isEmpty ? tr('点按查看任务') : e.title)
          : '$tool · ${e.title}';
    } else {
      final pv = (e.preview ?? '').trim();
      if (pv.isNotEmpty) {
        body = pv.length > 60 ? '${_cutAtCodePoint(pv, 60)}…' : pv;
      } else {
        body = e.title.isEmpty ? tr('点按查看任务列表') : e.title;
      }
    }
    // 审批快捷动作（2026-11-14）：通知栏 [批准] [拒绝] 直接应答——
    // payload 携完整审批意图 JSON（后台 isolate 落盘 → 主 isolate
    // 轮询消费活连接执行）。仅 interactionId 在手的审批事件携带。
    List<NotifyNotificationAction>? actions;
    if (e.kind == NotifyEventKind.approvalPending &&
        (e.interactionId ?? '').isNotEmpty) {
      String actionPayload(String act) => jsonEncode({
            'sid': e.deviceSid,
            'task': e.taskId,
            'kind': 'approval-action',
            'at': e.atMs,
            'iid': e.interactionId,
            'act': act,
            'title': e.title,
          });
      actions = [
        NotifyNotificationAction('accept', tr('批准'),
            actionPayload(_approvalActionChoiceAccept)),
        NotifyNotificationAction('decline', tr('拒绝'),
            actionPayload(_approvalActionChoiceDecline)),
      ];
    }
    try {
      await backend.show(
        id,
        title,
        body,
        // 任务完成横幅（orientation-unlock-1）：开=走高优渠道顶部弹窗，
        // 关=原 default 档渠道（「完成不打断」2026-10-20 拍板不变）。
        e.channel == NotifyChannel.tasks && (taskHeadsUpResolver?.call() ?? false)
            ? channelTasksAlert
            : channelOf(e.channel),
        NotifyTapPayload(e.deviceSid, e.taskId, e.kind.name, atMs: e.atMs,
                interactionId: e.interactionId)
            .encode(),
        actions: actions ?? const [],
      );
      _active[id] = (e.taskId, e.channel);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 审批快捷动作在栏（触发轮询启停用）。
  bool get hasActiveApprovals =>
      _active.values.any((c) => c == NotifyChannel.approvals);

  /// 审批快捷动作已受理——取消该会话的审批通知。
  Future<void> cancelApprovalForSession(String sessionId) async {
    final id = _idsByTask['${NotifyChannel.approvals.name}:$sessionId'];
    if (id == null) return;
    await backend.cancel(id);
    _active.remove(id);
    _idsByTask.remove('${NotifyChannel.approvals.name}:$sessionId');
  }

  /// 回前台清过时通知（Tactic 借鉴）：任务/Goal 通道全清（完成类通知
  /// 在回前台后已无提醒价值），审批通道只保留仍在等待的。
  /// [limitToIds]：只清这个 id 集合（=回前台时刻已在栏的快照——回前台
  /// 后新发的通知（如"你不在时完成了 N 个"聚合）不清，否则刚发即被
  /// 3s 清理定时器吃掉）。
  Future<void> clearStale({
    required Set<String> stillPendingTaskIds,
    Set<int>? limitToIds,
  }) async {
    final candidates = limitToIds ?? _active.keys.toList();
    final staleIds = <int>[];
    for (final id in candidates) {
      final info = _active[id];
      if (info == null) continue;
      final (taskId, channel) = info;
      switch (channel) {
        case NotifyChannel.tasks:
        case NotifyChannel.goals:
          staleIds.add(id);
        case NotifyChannel.approvals:
          if (!stillPendingTaskIds.contains(taskId)) staleIds.add(id);
      }
    }
    for (final id in staleIds) {
      try {
        await backend.cancel(id);
      } catch (_) {}
      final info = _active.remove(id);
      // 同步回收 id 簿条目——_idsByTask
      // 此前只增不减（FGS 常驻数周场景纯泄漏型增长）。
      if (info != null) {
        _idsByTask.remove('${info.$2.name}:${info.$1}');
      }
    }
  }

  /// 当前活跃通知 id 快照（回前台清过时的候选集来源）。
  Set<int> activeNotificationIds() => Set<int>.of(_active.keys);

  /// 通知点击（前台运行时回调入口，backend 转发）。
  void handleTap(NotifyTapPayload payload) => onTap?.call(payload);
}

/// 生产后端（flutter_local_notifications 封装）。只在有平台通道的环境
/// 构造（main.dart）；纯测试注入 FakeBackend。
class FlutterLocalNotificationsBackend implements NotificationBackend {
  FlutterLocalNotificationsBackend();

  final _plugin = FlutterLocalNotificationsPlugin();
  void Function(NotifyTapPayload payload)? _onTap;

  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {
    _onTap = handler;
  }

  @override
  Future<bool> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Darwin（早前批次）：初始化不自动请求权限——由
    // 「审批提醒」开关触发的 requestPermission 按需请求（对齐 Android
    // 侧权限被拒回弹开关的语义；弹窗时机=用户主动开启，不冷启骚扰）。
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(android: android, iOS: darwin);
    final ok = await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = NotifyTapPayload.decode(response.payload);
        if (payload != null) _onTap?.call(payload);
      },
      // 动作按钮按压在后台 isolate 回调（插件约定：顶层函数 +
      // vm:entry-point）。这里只落盘审批意图 + 受理反馈通知——
      // 真正的审批执行在主 isolate 轮询消费（活连接在那边）。
      onDidReceiveBackgroundNotificationResponse:
          notificationActionBackgroundHandler,
    );
    // iOS 返回值语义修正（早前批次 对抗审查发现）：插件把
    // 「本次是否请求/获得权限」当 initialize 返回值——按需请求形态
    // （三项 false）下恒回 NO（插件 .m requestPermissionsImpl 同步
    // result(NO)）。Android 无条件 true。若把 NO 当「后端未就绪」，
    // post() 首行短路 → iOS 一条通知都发不出。iOS 就绪门=调用完成
    // 不抛（恒 true 语义保留）；真实可用性由 requestPermission 按需
    // 请求、冷启动复查由 checkPermission 只读探得——两者都不改变本
    // 方法的就绪判定。
    if (defaultTargetPlatform == TargetPlatform.iOS) return true;
    return ok ?? false;
  }

  @override
  Future<bool> requestPermission() async {
    // iOS：alert/sound/badge 三项一次请求（不用 provisional——
    // 静默横幅非本产品形态，审批提醒需要醒目呈现）。
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, sound: true, badge: true) ??
          false;
    }
    final impl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await impl?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<bool?> checkPermission() async {
    try {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        // 22.3.2 实查（pub 缓存 platform_flutter_local_notifications.dart:
        // 780 与 notification_enabled_options.dart）：checkPermissions()
        // 返回 NotificationsEnabledOptions?，字段均以 is* 前缀命名
        // ——没有名为 alert 的字段，呈现权限字段是 isAlertEnabled。
        // 本产品请求 alert/sound/badge 三项，alert 关=横幅/弹窗被系统
        // 压掉（审批提醒的实际可达性），按「无权限」处理。
        final options = await ios.checkPermissions();
        return options?.isAlertEnabled;
      }
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Android 13+ 实查用户开关；旧版本无应用级开关恒回 true。
      // 方法签名 Future<bool?>（platform_flutter_local_notifications.dart:
      // 624），通道未就绪时 null 原样上抛语义=查询不可用。
      return await android?.areNotificationsEnabled();
    } catch (_) {
      // 平台通道未就绪/插件异常：查询不可用，调用方维持现有开关态。
      return null;
    }
  }

  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload, {
    List<NotifyNotificationAction> actions = const [],
  }) async {
    final details = AndroidNotificationDetails(
      channel,
      _channelName(channel),
      // 单色小图标（fullsweep-1108）：默认 ic_launcher 是全图 alpha=255
      // 的启动图标，状态栏渲染成实心方块——改用 alpha-only 矢量 Z。
      icon: 'ic_notification',
      // heads-up 档（orientation-unlock-1）：approvals 常驻高优；
      // tasks_alert=用户开关的任务完成横幅档，与 approvals 同级。
      importance: channel == NotificationService.channelApprovals ||
              channel == NotificationService.channelTasksAlert
          ? Importance.max
          : Importance.defaultImportance,
      priority: channel == NotificationService.channelApprovals ||
              channel == NotificationService.channelTasksAlert
          ? Priority.high
          : Priority.defaultPriority,
      autoCancel: true,
      // 审批快捷动作按钮（2026-11-14）：[批准] [拒绝] 通知栏直接应答；
      // 意图 JSON 在 payload（后台 isolate 落盘 → 主 isolate 消费）。
      actions: [
        for (final a in actions) AndroidNotificationAction(a.id, a.title),
      ],
      // 自动过期（ 决策 1）：tasks/goals 30 分钟后自动出栏，
      // approvals 不过期。策略在 notify_core.notificationTtlMs（纯函数，
      // 单测覆盖），此处只接线；字段=毫秒（flutter_local_notifications
      // 22.3.2 AndroidNotificationDetails.timeoutAfter），仅 Android
      // 生效（本项目唯一平台）。tasks_alert 同 tasks 的 30 分钟出栏
      // （横幅只是呈现档，过期语义同通道）。
      timeoutAfter: notificationTtlMs(
        channel == NotificationService.channelTasksAlert
            ? NotificationService.channelTasks
            : channel,
      ),
    );
    // Darwin（早前批次）：iOS 无 channel/timeoutAfter 概念
    // ——呈现等价（默认呈现层级，权限已含 alert/sound）；「不过期」语义
    // 与 Android approvals 档一致（tasks/goals 的 30 分钟出栏仅 Android，
    // iOS 由用户划掉，量级相同无噪声顾虑）。
    // 早前批次 ：interruptionLevel 分档——审批是有时效的交
    // 互（180s 倒计时），专注模式下普通 active 档会被系统压掉，故
    // approvals 用 timeSensitive（需配套 Time Sensitive entitlement，见
    // ios/Runner/*.entitlements）；其余通道维持 active（系统默认档的
    // 显式写法，语义与旧行为一致）。
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: details,
        iOS: DarwinNotificationDetails(
          interruptionLevel: channel == NotificationService.channelApprovals
              ? InterruptionLevel.timeSensitive
              : InterruptionLevel.active,
        ),
      ),
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async {
    try {
      final list = await _plugin.getActiveNotifications();
      return [
        for (final n in list)
          if (n.id != null)
            NotifyActiveEntry(
              id: n.id!,
              channelId: n.channelId,
              payload: n.payload,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> launchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        return details?.notificationResponse?.payload;
      }
    } catch (_) {}
    return null;
  }

  static String _channelName(String id) => switch (id) {
    NotificationService.channelApprovals => tr('审批提醒'),
    NotificationService.channelTasks => tr('任务完成'),
    // 系统设置里用户可见的渠道名——「横幅」后缀与 tasks 区分。
    NotificationService.channelTasksAlert => tr('任务完成（横幅）'),
    NotificationService.channelGoals => tr('目标进展'),
    _ => id,
  };
}
