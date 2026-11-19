// 应用锁设置页（app-lock-1）：方式三态（关/系统锁屏/PIN）+自动锁定
// 时机+锁定期防泄露开关。安全规则：从 system/pin 切走或关闭需先通过
// 当前方式验证（防旁人关锁）；开启「系统锁屏」前置校验设备有无系统锁
// （无则人话提示+引导跳系统安全设置，回弹——审批提醒 setAlertsEnabled
// 回弹模式先例）。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import '../core/app_lock.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';
import '../platform/capabilities.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart' show AppSectionHeader;

class SettingsSecurityPage extends StatefulWidget {
  const SettingsSecurityPage({super.key});

  @override
  State<SettingsSecurityPage> createState() => _SettingsSecurityPageState();
}

class _SettingsSecurityPageState extends State<SettingsSecurityPage> {
  static const _channel = MethodChannel('companion/app_lock');
  String? _error;

  AppLockMode get _mode =>
      appLockModeFromString(AppStateScope.of(context).uiPrefs.appLockModeRaw);

  /// 切换前验证（防旁人关锁）：当前 system/pin 模式下改选其他方式，
  /// 先过一次当前验证。
  Future<bool> _verifyCurrent(AppState app) async {
    final m = appLockModeFromString(app.uiPrefs.appLockModeRaw);
    if (m == AppLockMode.system) {
      try {
        return await _channel.invokeMethod<bool>('requestSystemUnlock') == true;
      } catch (_) {
        return false;
      }
    }
    if (m == AppLockMode.pin) {
      // 恢复出口：材料不健康（缺失/垃圾）时验证无意义且必然死路
      //（旧缺陷：设置页被软锁死只能清数据）——直接放行进入重设流程。
      if (!pinMaterialHealthy(
        app.uiPrefs.appLockPinSalt,
        app.uiPrefs.appLockPinHash,
      )) {
        return true;
      }
      // 验旧不校验形态（validateFormat:false）——只做哈希比对。
      final pin = await _askPin(
        tr('输入当前 PIN 码以继续'),
        validateFormat: false,
      );
      if (pin == null) return false;
      try {
        return hashPin(pin, app.uiPrefs.appLockPinSalt ?? '') ==
            app.uiPrefs.appLockPinHash;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  /// [validateFormat]=false 用于**验旧 PIN**：存量 PIN 可能是旧
  /// int.tryParse 时代合法设置的 +123/0x1f 形态（发布预审：新正则若
  /// 同时作用于验旧，这类用户被锁死在「验证未通过」无法自救）；设新
  /// PIN 恒严格校验。
  Future<String?> _askPin(
    String title, {
    String? confirmAgainst,
    bool validateFormat = true,
  }) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: AppType.uiBase)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: tr('4-6 位数字'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: Text(tr('取消'))),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: Text(tr('确定'))),
        ],
      ),
    );
    final v = ctrl.text;
    ctrl.dispose();
    if (ok != true) return null;
    // 早前批次：int.tryParse 接受 0x1f/+123 等形态——设新 PIN 统一纯数字
    // 正则；验旧（validateFormat=false）不校验形态原样比较（存量符号
    // PIN 用户可自救改锁，发布预审）。
    if (validateFormat && !RegExp(r'^\d{4,6}$').hasMatch(v)) {
      _showError(tr('PIN 需为 4-6 位数字'));
      return null;
    }
    if (confirmAgainst != null && v != confirmAgainst) {
      _showError(tr('两次输入不一致'));
      return null;
    }
    return v;
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() => _error = msg);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _selectMode(AppState app, AppLockMode target) async {
    setState(() => _error = null);
    final current = _mode;
    if (target == current) return;
    // 关闭/切换需先验证当前模式。
    if (current != AppLockMode.none && !await _verifyCurrent(app)) {
      _showError(tr('验证未通过，保持原设置'));
      return;
    }
    switch (target) {
      case AppLockMode.none:
        await app.uiPrefs.setAppLockMode('none');
        await app.uiPrefs.clearAppLockPin();
        app.appLock.loadFromPrefs(
          mode: AppLockMode.none,
          autoLockSeconds: app.uiPrefs.appLockAutoLockSeconds,
          secureFlagPref: app.uiPrefs.appLockSecureFlag,
        );
      case AppLockMode.system:
        // 前置校验：设备有无系统锁。
        bool secure = false;
        try {
          secure = await _channel.invokeMethod<bool>('isDeviceSecure') == true;
        } catch (_) {}
        if (!secure) {
          _showError(tr('此设备未设置系统屏幕锁，请先在系统设置中配置锁屏'));
          await _openSystemSecuritySettings();
          return;
        }
        await app.uiPrefs.setAppLockMode('system');
        app.appLock.loadFromPrefs(
          mode: AppLockMode.system,
          autoLockSeconds: app.uiPrefs.appLockAutoLockSeconds,
          secureFlagPref: app.uiPrefs.appLockSecureFlag,
          pinSalt: app.uiPrefs.appLockPinSalt,
          pinHash: app.uiPrefs.appLockPinHash,
        );
      case AppLockMode.pin:
        final first = await _askPin(tr('设置 PIN 码'));
        if (first == null) return;
        final second = await _askPin(tr('再次输入确认'));
        if (second == null) return;
        if (first != second) {
          _showError(tr('两次输入不一致'));
          return;
        }
        final salt = randomPinSalt();
        await app.uiPrefs.setAppLockPin(salt, hashPin(first, salt));
        await app.uiPrefs.setAppLockMode('pin');
        app.appLock.loadFromPrefs(
          mode: AppLockMode.pin,
          autoLockSeconds: app.uiPrefs.appLockAutoLockSeconds,
          secureFlagPref: app.uiPrefs.appLockSecureFlag,
          pinSalt: salt,
          pinHash: hashPin(first, salt),
        );
    }
  }

  Future<void> _openSystemSecuritySettings() async {
    try {
      await _channel.invokeMethod<void>('openSecuritySettings');
    } catch (_) {}
  }

  Future<void> _changePin(AppState app) async {
    if (!await _verifyCurrent(app)) {
      _showError(tr('验证未通过'));
      return;
    }
    final first = await _askPin(tr('设置新 PIN 码'));
    if (first == null) return;
    final second = await _askPin(tr('再次输入确认'));
    if (second == null || first != second) {
      if (mounted && second != null) _showError(tr('两次输入不一致'));
      return;
    }
    final salt = randomPinSalt();
    await app.uiPrefs.setAppLockPin(salt, hashPin(first, salt));
    // 重装 controller（发布预审：恢复路径（材料损坏→跳验旧→重设）走完
    // 后若不重装，AppLockGate 已 _armed 不再自动装载——本会话锁保持
    // 关闭直到冷启动。健康路径重设同享此修复，行为=立即生效）。
    app.appLock.loadFromPrefs(
      mode: AppLockMode.pin,
      autoLockSeconds: app.uiPrefs.appLockAutoLockSeconds,
      secureFlagPref: app.uiPrefs.appLockSecureFlag,
      pinSalt: app.uiPrefs.appLockPinSalt,
      pinHash: app.uiPrefs.appLockPinHash,
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('PIN 码已更新'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final ui = app.uiPrefs;
    final mode = _mode;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(tr('应用锁'), style: const TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListenableBuilder(
        listenable: ui,
        builder: (context, _) => ListView(
          children: [
            // 损坏态横幅：mode=pin 但材料缺失/垃圾——旧验证路径
            // 必然死路；横幅明示可直接重设（切换/重设流程已跳过验旧 PIN）。
            if (mode == AppLockMode.pin &&
                !pinMaterialHealthy(
                  ui.appLockPinSalt,
                  ui.appLockPinHash,
                )) ...[
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.colors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: context.colors.warning),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_outlined,
                        size: 16, color: context.colors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr('应用锁数据已损坏（PIN 材料缺失或无效），验证已被'
                            '跳过。请重新设置 PIN 码，或切换到其他解锁方式。'),
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          height: 1.5,
                          color: context.colors.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            AppSectionHeader(tr('解锁方式')),
            _modeTile(app, AppLockMode.none, tr('关闭'), tr('不使用应用锁')),
            _modeTile(
                app, AppLockMode.system, tr('系统锁屏'), tr('指纹 / 面容 / 图案 / PIN（跟随系统锁设置）')),
            _modeTile(app, AppLockMode.pin, tr('PIN 码'), tr('应用内独立 PIN 码')),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                tr('开启后每次冷启动需验证；切换或关闭应用锁需先通过当前方式验证。'),
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                  height: 1.5,
                ),
              ),
            ),
            if (mode != AppLockMode.none) ...[
              AppSectionHeader(tr('自动锁定')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 0, label: Text(tr('立即'))),
                    ButtonSegment(value: 30, label: Text(tr('30 秒'))),
                    ButtonSegment(value: 60, label: Text(tr('1 分钟'))),
                    ButtonSegment(value: 300, label: Text(tr('5 分钟'))),
                  ],
                  selected: {ui.appLockAutoLockSeconds},
                  onSelectionChanged: (s) {
                    ui.setAppLockAutoLockSeconds(s.first);
                    app.appLock.loadFromPrefs(
                      mode: mode,
                      autoLockSeconds: s.first,
                      secureFlagPref: ui.appLockSecureFlag,
                      pinSalt: ui.appLockPinSalt,
                      pinHash: ui.appLockPinHash,
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(
                  tr('冷启动始终需要验证；此处控制切后台多久后需要重新验证。'),
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
              // iOS 隐藏（早前批次 对抗审查）：FLAG_SECURE 无
              // iOS 等价（setSecureFlag 通道 no-op）——开着=假开关违反
              // 「UI 不撒谎」红线。切换器遮罩的降级形态实现后再以
              // supportsSecureFlag 语义回归（留项）。
              if (ZpCapabilities.supportsSecureFlag)
                SwitchListTile(
                value: ui.appLockSecureFlag,
                onChanged: (v) {
                  ui.setAppLockSecureFlag(v);
                  app.appLock.loadFromPrefs(
                    mode: mode,
                    autoLockSeconds: ui.appLockAutoLockSeconds,
                    secureFlagPref: v,
                    pinSalt: ui.appLockPinSalt,
                    pinHash: ui.appLockPinHash,
                  );
                },
                title: Text(tr('锁定时防截屏与缩略图')),
                subtitle: Text(
                  tr('仅锁定界面期间生效；解锁后可正常截屏'),
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
            ],
            if (mode == AppLockMode.pin)
              ListTile(
                key: const ValueKey('settings-change-pin'),
                leading: const Icon(Icons.pin_outlined),
                title: Text(tr('修改 PIN 码')),
                onTap: () => _changePin(app),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: AppType.uiCaption, color: context.colors.destructive),
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _modeTile(AppState app, AppLockMode m, String title, String subtitle) {
    return RadioListTile<AppLockMode>(
      value: m,
      groupValue: _mode,
      onChanged: (_) => _selectMode(app, m),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: AppType.uiCaption,
          color: context.colors.foregroundSubtle,
        ),
      ),
      controlAffinity: ListTileControlAffinity.trailing,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }
}
