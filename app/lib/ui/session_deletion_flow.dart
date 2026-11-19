// ③ 会话永久删除流（早前批次，用户拍板防呆设计：「用户需要确认，比起
// 单纯的点击，可能需要用户设置密码后输入密码，才确认删除，毕竟不可
// 恢复」；早前批次 按对抗审查全修）。
//
// 协议：官方 zcode-task 频道 previewArchivedTaskDeletion /
// permanentlyDeleteArchivedTask（两阶段：preview 返回范围指纹 revision；
// execute 回传 revision+operationId，服务端重算比对，不一致=blocked+
// changed 零破坏）。UI 三段防呆：范围预览（删什么/留什么）→ 凭证闸门
// → 执行结果（deleted/blocked/incomplete/未知四态人话，不谎报成功）。
//
// 早前批次 要点：
// - 预览/执行 future 均在 dialog 外创建（builder 重建不重发、
//   operationId 单次生成保幂等）；
// - 执行弹窗 PopScope(canPop:false)——返回键不再吞掉不可逆操作的结果
//   反馈（update_flow 同款）；
// - 载荷全走 payload_guard（形态漂移不崩弹窗）；
// - 闸门三态：pin+材料健康→PIN 框 / system→系统锁屏凭证（用户拍板，
//   复用应用锁遮罩通道） / 其余→中性引导（PIN 或系统锁屏均可）；
// - execute 返回 null/未知 status →「结果未知」而非谎报 incomplete。
import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/app_lock.dart' show PinAttemptLimiter, hashPin, pinMaterialHealthy;
import '../core/localized_text.dart';
import '../core/l10n.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../transport/id.dart' show generateUuid;
import 'app_widgets.dart';
import 'settings_security_page.dart';

/// blockedReason → 人话（官方词表语义：running/in-use/not-found/
/// not-archived 由 Host 适配层追加；changed/unavailable 是 execute 侧）。
String deletionBlockedReasonText(String reason) => switch (reason) {
      'running' => '该任务仍有工作在运行（或有待处理输入），先停止后再删',
      'in-use' => '会话正被其他程序占用（例如桌面端另一窗口打开着它）',
      'not-found' => '没有找到该任务的会话数据（可能已被删除）',
      'not-archived' => '任务已不在归档状态，请先归档后再永久删除',
      'changed' => '删除范围已发生变化（预览后有新内容），请重新预览',
      'unavailable' => '暂时无法完成删除，稍后重试',
      _ => '本次无法删除：$reason',
    };

/// 防误触限流（模块级：跨对话框实例存活——取消重开不清零；进程重启
/// 复位。定位=防随手乱点的速度缓冲，**非安全控制**：PIN 是本地盐+
/// SHA-256，威胁模型=防旁人翻看非对抗取证，见 app_lock.dart 头注）。
PinAttemptLimiter _pinAttemptLimiter = PinAttemptLimiter();

/// 测试隔离缝（跨用例复位冷却/计数；生产不得调用）。
@visibleForTesting
void resetDeletionPinLimiter() {
  _pinAttemptLimiter = PinAttemptLimiter();
}


/// 入口：从归档任务页点「永久删除」。
Future<void> showPermanentDeletionFlow(
  BuildContext context, {
  required Map<String, dynamic> task,
}) async {
  final app = AppStateScope.of(context);
  final taskId = '${task['taskId']}';
  final title = '${task['title'] ?? ''}'.trim().isEmpty
      ? '未命名任务'
      : '${task['title']}';

  // ── 第一段：范围预览（服务端权威——revision 指纹随范围变化）──
  // future 在 dialog 外创建（builder 重建不重发只读查询）。
  final previewFuture = app.previewArchivedTaskDeletion(taskId);
  final verifyLabel = app.uiPrefs.appLockModeRaw == 'system'
      ? tr('继续（需系统验证）')
      : tr('继续（需验证 PIN）');
  final preview = await showDialog<Map<String, dynamic>?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => FutureBuilder<dynamic>(
      future: previewFuture,
      builder: (dctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return AlertDialog(
            title: Text(tr('正在核对删除范围…')),
            content: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [AppLoading('')],
            ),
          );
        }
        if (snap.hasError) {
          return AlertDialog(
            title: Text(tr('无法预览删除范围')),
            content: Text(
              '${tr('加载失败：')}${snap.error}',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: dctx.colors.destructive,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: Text(tr('关闭')),
              ),
            ],
          );
        }
        final p = snap.data;
        return _PreviewDialog(
          preview: p is Map ? p.cast<String, dynamic>() : const {},
          title: title,
          verifyLabel: verifyLabel,
        );
      },
    ),
  );
  if (preview == null || !context.mounted) return;
  final revision = '${preview['revision'] ?? ''}';
  if (revision.isEmpty) return;

  // ── 第二段：凭证闸门（三态：PIN 框、系统锁屏凭证、引导设置）──
  final gateOk = await _gate(context, app);
  if (gateOk != true || !context.mounted) return;

  // ── 第三段：执行（revision 回传；operationId 单次生成保幂等；
  // future 在 dialog 外创建；PopScope 挡返回键防结果静默丢失）──
  final messenger = ScaffoldMessenger.of(context);
  final executeFuture = app.permanentlyDeleteArchivedTask(
    taskId,
    revision: revision,
    operationId: generateUuid(),
  );
  final dialogOpen = Completer<void>();
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(tr('正在永久删除…')),
          content: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [AppLoading('')],
          ),
        ),
      ),
    ).whenComplete(() => dialogOpen.complete()),
  );
  try {
    final res = await executeFuture;
    if (context.mounted && !dialogOpen.isCompleted) {
      Navigator.of(context).pop();
    }
    _reportExecuteResult(messenger, res, title);
  } catch (e) {
    if (context.mounted && !dialogOpen.isCompleted) {
      Navigator.of(context).pop();
    }
    messenger.showSnackBar(
      SnackBar(content: Text('${tr('删除失败：')}$e')),
    );
  }
}

/// 执行结果四态人话（早前批次：null/未知 →「结果未知」，不谎报
/// incomplete——bridge 断开等场景一个字节都没删时绝不能说「部分已清理」）。
void _reportExecuteResult(
  ScaffoldMessengerState messenger,
  dynamic res,
  String title,
) {
  if (res is! Map) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('删除结果未知，请刷新任务列表核对'))),
    );
    return;
  }
  switch ('${res['status'] ?? ''}') {
    case 'deleted':
      messenger.showSnackBar(
        SnackBar(content: Text(tr('已永久删除「') + title + tr('」'))),
      );
    case 'blocked':
      final reason = '${res['reason'] ?? ''}';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${tr('未删除：')}${tr(deletionBlockedReasonText(reason.isEmpty ? 'unavailable' : reason))}',
          ),
        ),
      );
    case 'incomplete':
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('删除未完成（部分数据已清理），可稍后重试继续')),
        ),
      );
    default:
      messenger.showSnackBar(
        SnackBar(content: Text(tr('删除结果未知，请刷新任务列表核对'))),
      );
  }
}

/// 范围预览对话框（「删什么/留什么」+ blocked 态 + 永久删除按钮）。
/// 返回非 null=用户已确认范围（带 revision），交凭证闸门。
/// 载荷全走 payload_guard（早前批次 ：裸强转会让形态漂移把弹窗打成
/// ErrorWidget 且 barrierDismissible=false 关不掉）。
class _PreviewDialog extends StatelessWidget {
  final String title;
  final Map<String, dynamic> preview;
  final String verifyLabel;
  const _PreviewDialog({
    required this.title,
    required this.preview,
    required this.verifyLabel,
  });

  @override
  Widget build(BuildContext context) {
    final sessionIds = [
      for (final s in listOf(preview['sessionIds']) ?? const []) '$s',
    ];
    final deletedFiles = numOf(preview['deletedFiles']) ?? 0;
    final forks = [
      for (final f in listOf(preview['forks']) ?? const [])
        if (f is Map) '${f['title'] ?? ''}',
    ];
    final retained = [
      for (final a in listOf(preview['retainedArtifacts']) ?? const [])
        if (a is Map) '${a['fileName'] ?? a['artifactId'] ?? ''}',
    ];
    final blockedReason = '${preview['blockedReason'] ?? ''}';
    final incomplete = preview['incomplete'] == true;
    final completed = preview['completed'] == true;
    // 官方语义：树为空（sessionIds 空）且无 blockedReason=not-found 同义
    // 展示；revision 缺失=宿主形态异常，不可进执行。
    final emptyTree =
        blockedReason.isEmpty && !completed && sessionIds.isEmpty;
    final revisionOk = '${preview['revision'] ?? ''}'.isNotEmpty;
    final deletable =
        blockedReason.isEmpty && !completed && !emptyTree &&
        sessionIds.isNotEmpty && revisionOk;

    return AlertDialog(
      key: const ValueKey('perm-del-preview'),
      title: Text(
        tr('永久删除「') + title + tr('」？'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (completed) ...[
              Text(tr('该任务的会话数据已被彻底删除。')),
            ] else if (blockedReason.isNotEmpty || emptyTree) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.block_outlined,
                    size: 16,
                    color: context.colors.destructive,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tr(
                        deletionBlockedReasonText(
                          emptyTree ? 'not-found' : blockedReason,
                        ),
                      ),
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.destructive,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colors.destructive.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.delete_forever_outlined,
                      size: 16,
                      color: context.colors.destructive,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('将永久删除：任务本体'
                            '（含子智能体 / 工作流子会话共 ') +
                            '${sessionIds.length}' +
                            tr(' 个会话）与 ') +
                            '$deletedFiles' +
                            tr(' 个文件。删除后不可恢复。'),
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (incomplete) ...[
                const SizedBox(height: 8),
                Text(
                  tr('上次删除未完成，本次将继续清理剩余数据。'),
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.warning,
                  ),
                ),
              ],
              if (forks.isNotEmpty || retained.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  tr('以下内容将保留：'),
                  style: const TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final f in forks)
                  Text(
                    '· ${tr('分支会话')}「$f」',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                for (final r in retained)
                  Text(
                    '· ${tr('产物')} $r${tr('（被其他会话引用）')}',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                Text(
                  '· ${tr('工作区文件、Git 记录、分享不受影响')}',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('perm-del-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(tr('取消')),
        ),
        if (deletable)
          FilledButton(
            key: const ValueKey('perm-del-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.destructive,
            ),
            onPressed: () => Navigator.pop(context, preview),
            child: Text(verifyLabel),
          ),
      ],
    );
  }
}

/// 凭证闸门：返回 true=通过。
/// 三态（用户拍板）：pin+材料健康→PIN 框；system→系统锁屏凭证
///（复用应用锁遮罩通道，验证强度高于 4-6 位数字 PIN，不强迫 system
/// 用户降级锁方式）；其余（none / pin 材料损坏）→中性引导。
Future<bool?> _gate(BuildContext context, AppState app) async {
  final prefs = app.uiPrefs;
  final salt = prefs.appLockPinSalt;
  final hash = prefs.appLockPinHash;
  if (prefs.appLockModeRaw == 'pin' && pinMaterialHealthy(salt, hash)) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _PinVerifyDialog(saltHex: salt!, pinHash: hash!),
    );
  }
  if (prefs.appLockModeRaw == 'system') {
    final ok = await app.appLock.unlockWithSystem();
    if (ok) return true;
    // 取消/验证失败=停留可重试（返回 false 中止本次流）；设备无锁可验
    //（systemUnlockUnavailable）才走引导配锁。
    if (app.appLock.systemUnlockUnavailable.value && context.mounted) {
      await _showSetupGuidance(context);
    }
    return false;
  }
  await _showSetupGuidance(context);
  return false;
}

Future<void> _showSetupGuidance(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (dctx) => AlertDialog(
      key: const ValueKey('perm-del-pin-missing'),
      title: Text(tr('需要先设置 PIN')),
      content: Text(
        tr('永久删除不可恢复。为防误删，请先在「设置 → 安全」开启应用锁'
            '（PIN 或系统锁屏均可），再回来执行永久删除。'),
        style: TextStyle(fontSize: AppType.uiCaption, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx),
          child: Text(tr('取消')),
        ),
        FilledButton(
          key: const ValueKey('perm-del-goto-settings'),
          onPressed: () {
            Navigator.pop(dctx);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SettingsSecurityPage(),
              ),
            );
          },
          child: Text(tr('去设置')),
        ),
      ],
    ),
  );
}

/// PIN 输入对话框（盐+SHA-256 本地校验；限流器为模块级共享——取消重开
/// 不清零，5 错 30s 冷却在整个 app 会话内有效）。
class _PinVerifyDialog extends StatefulWidget {
  final String saltHex;
  final String pinHash;
  const _PinVerifyDialog({required this.saltHex, required this.pinHash});

  @override
  State<_PinVerifyDialog> createState() => _PinVerifyDialogState();
}

class _PinVerifyDialogState extends State<_PinVerifyDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _verify() {
    final pin = _controller.text.trim();
    if (pin.isEmpty) return;
    final cooldown = _pinAttemptLimiter.cooldownRemaining(DateTime.now());
    if (cooldown > 0) {
      setState(
        () => _error = '${tr('尝试过多，请')} $cooldown ${tr('秒后再试')}',
      );
      return;
    }
    // 闸门已用 pinMaterialHealthy 过滤非法盐——此处 try/catch 为纵深
    // 防御（材料在闸门与验证间被写坏的理论窗口）。
    bool matched;
    try {
      matched = hashPin(pin, widget.saltHex) == widget.pinHash;
    } catch (_) {
      matched = false;
    }
    if (matched) {
      // 成功复位计数（发布预审：共享实例成功不清零会把「连续错 5 次」
      // 变成跨流程累计——隔次删除第 1 次输错即误触冷却）。
      _pinAttemptLimiter.recordSuccess();
      Navigator.pop(context, true);
      return;
    }
    final cd = _pinAttemptLimiter.recordFailure(DateTime.now());
    setState(() {
      _controller.clear();
      _error = cd > 0
          ? '${tr('PIN 不正确。尝试过多，请')} $cd ${tr('秒后再试')}'
          : tr('PIN 不正确，请重试');
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('perm-del-pin-verify'),
      title: Text(tr('输入 PIN 确认永久删除')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('该操作不可恢复，请输入应用锁 PIN 确认。'),
            style: TextStyle(fontSize: AppType.uiCaption, height: 1.5),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('perm-del-pin-input'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            // 与设置端一致：4-6 位数字（设置页 早前批次 同步收紧为
            // ^\d{4,6}$，消除 int.tryParse 接受 0x1f/+123 的两端口径差）。
            maxLength: 6,
            onSubmitted: (_) => _verify(),
            decoration: InputDecoration(
              counterText: '',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('perm-del-pin-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('取消')),
        ),
        FilledButton(
          key: const ValueKey('perm-del-pin-ok'),
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.destructive,
          ),
          onPressed: _verify,
          child: Text(tr('确认删除')),
        ),
      ],
    );
  }
}
