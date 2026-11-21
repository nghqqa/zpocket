import 'dart:async';

import 'package:flutter/foundation.dart';

import '../transport/marketing_client.dart';
import '../transport/relay_v2.dart' show RelayV2AuthRequired;

/// 卡面错误行的呈现分类（UI 据此选文案）。
enum MarketingClaimError {
  /// 服务端明确拒绝（文案透传，卡保留可重试）。
  server,

  /// 凭据缺失——本地文案引导重登，卡保留。
  authRequired,

  /// 传输异常：请求结果未知——卡保留可重试。
  uncertain,
}

/// 首页福利提醒卡状态机（marketing-claim-1，；marketing-reminder-1
/// 起收敛为 touch 投放展示+电脑端提醒——纯提醒语义，不在手机端领取）。
///
/// 拉取调度（审查②/ 修复）：
/// - 触发点=冷启动一次+卡片挂载 ensurePulled（经 AppStateScope 通知，
///   频率高）+下拉/顶栏刷新 force——**失败退避**（30s 起指数翻倍封顶
///   10min，成功即重置）挡住通知频率的重试风暴；账号 id 读取 60s 节流
///   缓存（每次 AppState 通知不再做两次 Keystore 往返）；账号变更经
///   [onAccountChanged] 显式失效缓存立即重拉。
/// - 每账号每会话成功一次；无后台轮询（电量红线）。
/// - 拉取失败保旧卡（SWR），但**跨账号的旧卡在拉取前即清**（审查①/
///   ②M2：B 会话不得展示 A 的投放），且 10 分钟无成功按官方
///   marketingTouchController.ts:190-198 语义收卡。
/// - 关闭的上报为 fire-and-forget（官方同款）——不阻塞结果反馈；
/// - suppress 按 `accountId:campaignId` 键控（跨账号不串）。
class MarketingController extends ChangeNotifier {
  /// 失败退避起点。
  static const backoffInitial = Duration(seconds: 30);

  /// 失败退避封顶（官方生产轮询间隔量级）。
  static const backoffMax = Duration(minutes: 10);

  /// 账号 id 读取节流间隔（Keystore 往返成本）。
  static const accountRecheckInterval = Duration(seconds: 60);

  /// 无成功拉取的旧卡保留上限（官方 600s 同款）。
  static const staleCardTtl = Duration(minutes: 10);

  final Future<String?> Function() accountIdProvider;
  final Future<String?> Function(String accountId) jwtProvider;
  final Future<String> Function() deviceMidProvider;
  final String Function() localeProvider;
  final Future<String> Function() appVersionProvider;
  final String Function() platformProvider;
  final Uri Function() originProvider;

  /// 可注入时钟（退避测试）。
  @visibleForTesting
  DateTime Function() clock;

  MarketingController({
    required this.accountIdProvider,
    required this.jwtProvider,
    required this.deviceMidProvider,
    required this.localeProvider,
    required this.appVersionProvider,
    required this.platformProvider,
    required this.originProvider,
    this.clock = _defaultClock,
  });

  static DateTime _defaultClock() => DateTime.now();

  /// 当前展示的领取卡（null=不出卡）。
  MarketingCard? card;

  /// 领取进行中（按钮转圈、防重复点击、拉取避让）。
  bool claiming = false;

  /// 拉取进行中（UI 不阻塞，仅诊断）。
  bool pulling = false;

  /// 卡面错误行（非终态失败；下次动作清空）。
  MarketingClaimError? errorKind;

  /// [MarketingClaimError.server] 的服务端文案（已翻译且已截断，可空）。
  String? serverErrorMessage;

  /// 收起态（marketing-claim-collapse-1，用户拍板「我现在不想领想晚点
  /// 领」）：键=账号+投放（见 [_key]）——**campaign 级延期语义**：同投放
  /// 跨 force 拉取/中间换投放后再投同 campaign 均保持收起（同一活动不
  /// 反复打扰）；换账号（键含账号）或重启回展开；会话级视图态不落盘
  /// 不上报（既非确认也非取消，官方无此概念）。与 dismiss 互不影响：
  /// dismiss 走 suppress+cancel 上报。
  String? _collapsedKey;

  /// 当前在展卡是否处于收起态。
  bool get isCollapsed {
    final current = card;
    return current != null &&
        _collapsedKey == _key(current.accountId, current.delivery.campaignId);
  }

  /// 收起[expected]这张卡（仅视图态；claiming 中禁用——与 UI 禁用同
  /// 口径；identical 校验防陈旧点击打到换卡后的新投放，审查②）。
  void collapse(MarketingCard expected) {
    final current = card;
    if (current == null || claiming || !identical(current, expected)) return;
    _collapsedKey = _key(current.accountId, current.delivery.campaignId);
    notifyListeners();
  }

  /// 展开当前卡（claiming 中也允许——展开后三钮全禁用，安全且对称
  /// 口径留痕：收起防跳变、展开无副作用）。
  void expand() {
    if (_collapsedKey == null) return;
    _collapsedKey = null;
    notifyListeners();
  }

  /// 会话内抑制：键=[_key]（账号+投放，长度前缀编码——见 [_key]；用户
  /// 关闭后该账号本会话不再打扰；不落盘——重启后若服务端仍投则再提醒）。
  final Set<String> _suppressed = <String>{};

  /// 每账号每会话已成功拉取过一次的账号集合。
  final Set<String> _pulledAccounts = <String>{};

  DateTime _nextAttemptAfter = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _backoff = backoffInitial;
  DateTime _lastSuccessAt = DateTime.fromMillisecondsSinceEpoch(0);

  // 账号缓存（审查②：避免每次 AppState 通知两次 Keystore 读）。
  String? _cachedAccountId;
  bool _cachedAccountValid = false;
  DateTime _accountReadAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void>? _inFlight;
  bool _pendingForce = false;

  /// 拉取入口（并发合并；在飞期间到达的 force 记待办，完成后重跑——
  /// 审查②：force 不被普通在飞吸收）。
  Future<void> pull({bool force = false}) {
    final running = _inFlight;
    if (running != null) {
      if (force) _pendingForce = true;
      return running;
    }
    final task = _pull(force: force).whenComplete(() {
      _inFlight = null;
      if (_pendingForce) {
        _pendingForce = false;
        unawaited(pull(force: true));
      }
    });
    _inFlight = task;
    return task;
  }

  /// 卡片挂载时的轻量入口：退避/每账号闸/60s 账号节流内零成本跳过。
  Future<void> ensurePulled() => pull(force: false);

  /// 账号变更钩子（AccountStore save/setLastUsed/removeAccount 后由
  /// AppState 调用）：失效账号缓存与退避，触发立即重拉。
  void onAccountChanged() {
    _cachedAccountValid = false;
    _nextAttemptAfter = DateTime.fromMillisecondsSinceEpoch(0);
    notifyListeners();
  }

  Future<String?> _resolveAccount({bool fresh = false}) async {
    final now = clock();
    if (!fresh &&
        _cachedAccountValid &&
        now.difference(_accountReadAt) < accountRecheckInterval) {
      return _cachedAccountId;
    }
    try {
      _cachedAccountId = await accountIdProvider();
      _cachedAccountValid = true;
      _accountReadAt = now;
    } catch (_) {
      // Keystore 读异常（华为机型不罕见）：保旧值，退避由 pull 兜。
    }
    return _cachedAccountId;
  }

  Future<void> _pull({required bool force}) async {
    if (claiming) return; // claiming 中不拉取。
    final now = clock();
    // 失败退避闸（force 绕过——下拉/顶栏刷新语义）。
    if (!force && now.isBefore(_nextAttemptAfter)) return;
    final accountId = await _resolveAccount(fresh: force);
    if (accountId == null || accountId.isEmpty) {
      // 无账号（未登录）——清卡静默。
      if (card != null) {
        card = null;
        notifyListeners();
      }
      return;
    }
    // 跨账号陈旧卡：拉取前即清（B 会话不得留 A 的卡——审查①/②M2）。
    if (card != null && card!.accountId != accountId) {
      card = null;
      errorKind = null;
      serverErrorMessage = null;
      notifyListeners();
    }
    if (!force && _pulledAccounts.contains(accountId)) return;
    pulling = true;
    notifyListeners();
    MarketingApiClient? client;
    var succeeded = false;
    try {
      client = await _clientFor(accountId);
      // marketing-diag-1：拉取起点（账号哈希前 8 位，无 PII）。
      // ignore: avoid_print
      print(
        '[marketing] pull 发起 acc=${accountId.hashCode.toRadixString(16).padLeft(8, '0')}',
      );
      final snapshot = await client.touch();
      succeeded = true;
      // ignore: avoid_print
      print(
        '[marketing] pull 成功 candidates=${snapshot.deliveries.where((d) => d.claimable).length} '
        'suppressed=${_suppressed.length}',
      );
      _pulledAccounts.add(accountId);
      // SWR 语义：拉到新快照才换卡（在途失败保旧卡）。
      final candidates = snapshot.deliveries
          .where(
            (d) =>
                d.claimable &&
                !_suppressed.contains(_key(accountId, d.campaignId)),
          )
          .toList();
      // banner 优先（带图资产概率最高），其次 popup；官方按
      // resource_position 去重已保证各至多一条。
      MarketingDelivery? chosen;
      for (final d in candidates) {
        if (d.position == 'banner') {
          chosen = d;
          break;
        }
      }
      if (chosen == null) {
        for (final d in candidates) {
          if (d.position == 'popup') {
            chosen = d;
            break;
          }
        }
      }
      if (chosen == null) {
        card = null;
      } else {
        // 同 campaign 重选不清错误提示。
        final sameCampaign =
            card != null && card!.delivery.campaignId == chosen.campaignId;
        if (!sameCampaign) {
          errorKind = null;
          serverErrorMessage = null;
        }
        card = MarketingCard(accountId: accountId, delivery: chosen);
      }
    } on RelayV2AuthRequired {
      // 凭据缺失/失效：不出卡不报错（账号管理有自己的引导）。
      // ignore: avoid_print
      print('[marketing] pull 失败=AuthRequired');
    } on MarketingUnavailable catch (e) {
      // 增益面：静默保旧卡（marketing-diag-1：失败原因上 logcat）。
      // ignore: avoid_print
      print('[marketing] pull 失败=$e');
    } catch (e) {
      // 未知异常同静默——首页永不因营销卡抛错（含 provider 抛错，
      // 审查②：不得让 pulling 卡死或异常裸奔）。
      // ignore: avoid_print
      print('[marketing] pull 未知异常=$e');
    } finally {
      client?.close();
      pulling = false;
      if (succeeded) {
        _backoff = backoffInitial;
        _lastSuccessAt = now;
      } else {
        // 失败退避：30s 起指数翻倍封顶 10min（成功重置）。
        _nextAttemptAfter = now.add(_backoff);
        _backoff = Duration(
          milliseconds: (_backoff.inMilliseconds * 2).clamp(
            0,
            backoffMax.inMilliseconds,
          ),
        );
        // 官方 10min 无成功收卡语义（审查②）。
        if (card != null &&
            _lastSuccessAt.millisecondsSinceEpoch > 0 &&
            now.difference(_lastSuccessAt) > staleCardTtl) {
          card = null;
          errorKind = null;
          serverErrorMessage = null;
        }
      }
      notifyListeners();
    }
  }

  /// 最近一次 dismiss 的快照（撤销用——审查①M2：X 误触不可逆代价）。
  MarketingCard? _lastDismissed;

  /// 用户主动关闭卡片。
  Future<void> dismiss(MarketingCard expected) async {
    final current = card;
    // identical 校验防陈旧点击 suppress/上报错投放（审查②）。
    if (current == null || claiming || !identical(current, expected)) return;
    _suppressed.add(_key(current.accountId, current.delivery.campaignId));
    _lastDismissed = current;
    card = null;
    errorKind = null;
    serverErrorMessage = null;
    notifyListeners();
    unawaited(_report(current, confirm: false));
  }

  /// 撤销最近一次 dismiss（SnackBar 动作）：恢复卡片并解除本会话抑制。
  /// cancel 上报已发出、不补发 confirm——分析数据容忍单向误差（决策记录
  /// 留痕）；若期间已换账号/出新卡则不恢复（只解除抑制，等下次拉取）。
  void undoDismiss() {
    final last = _lastDismissed;
    if (last == null) return;
    _lastDismissed = null;
    _suppressed.remove(_key(last.accountId, last.delivery.campaignId));
    if (card == null && !claiming) {
      card = last;
      errorKind = null;
      serverErrorMessage = null;
    }
    notifyListeners();
  }

  Future<void> _report(MarketingCard current, {required bool confirm}) async {
    try {
      final client = await _clientFor(current.accountId);
      try {
        await client.reportAction(
          current.delivery.campaignId,
          confirm: confirm,
        );
      } finally {
        client.close();
      }
    } catch (_) {
      // 分析上报失败不影响任何用户可见行为（官方 fire-and-forget）。
    }
  }

  Future<MarketingApiClient> _clientFor(String accountId) async {
    return MarketingApiClient(
      origin: originProvider(),
      jwtProvider: () => jwtProvider(accountId),
      deviceMid: await deviceMidProvider(),
      locale: _normalizeLocale(localeProvider()),
      appVersion: await appVersionProvider(),
      platform: platformProvider(),
    );
  }

  /// 官方 SUPPORTED_LOCALES 含 ja/ru/ko，本应用只有中英两档——
  /// 非英文一律报中文（服务端按此返回已翻译文案）。localeProvider 生产
  /// 接 L10n.resolvedLocale（仅 en-US/zh-CN 两值）；若未来接入原始系统
  /// locale 须先收窄此归一（审查③低-2 留痕）。
  static String _normalizeLocale(String raw) =>
      raw.toLowerCase().startsWith('en') ? 'en-US' : 'zh-CN';

  /// 键去歧义（collapse-1 审查②）：accountId/campaignId 均为服务端
  /// 可控任意串，`:` 拼接可造歧义键（u + a:b ≡ u:a + b）——长度前缀
  /// 编码无歧义；suppress 与收起共用本函数同步受益。
  static String _key(String accountId, String campaignId) =>
      '${accountId.length}:$accountId$campaignId';
}

/// 在展福利提醒卡：投放 + 归属账号（账号切换判定用）。
class MarketingCard {
  final String accountId;
  final MarketingDelivery delivery;
  const MarketingCard({required this.accountId, required this.delivery});
}
