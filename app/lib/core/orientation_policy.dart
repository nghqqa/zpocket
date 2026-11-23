import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'breakpoints.dart';

/// 方向策略纯函数（orientation-unlock-1，1.0.9 攒批）。
///
/// 用户拍板形态矩阵：直板/折叠收起态仅竖屏；展开态/平板随系统横竖。
/// 判定基准=**当前窗口短边**而非设备品类——旋转/键盘只改长边，短边
/// 不动，天然免疫抖动；且与双栏断点（breakpoints.formFactorOf）同源，
/// 同一门槛既驱动布局（≥600 双栏）也驱动方向（≥600 可旋转）。
/// 「像手机的锁竖，像平板/展开的随系统」，不看出厂品类（未来出现
/// 短边 ≥600 的「手机」按平板处理即正确——那个尺寸就是平板）。
///
/// 分屏（multi-window）返回全四方向=等效不限制（本 Flutter 版
/// setPreferredOrientations 参数不可空、无 null 语义）：半窗里锁方向
/// 只会 letterbox 或被 ROM 忽略，而布局断点本就按实际窗口自适应单
/// 双栏（FormFactorBuilder 的 LayoutBuilder 约束变化自动切换）。
List<DeviceOrientation> orientationTargetsFor({
  required double shortestSide,
  required bool multiWindow,
}) {
  if (multiWindow) return DeviceOrientation.values;
  final wide =
      formFactorOf(Size(shortestSide, shortestSide)) != AppFormFactor.compact;
  if (wide) {
    return const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ];
  }
  return const [DeviceOrientation.portraitUp];
}

/// 根部方向闸（挂 MaterialApp.builder 层=覆盖全部路由）。
///
/// Manifest 仍锁 portrait 作引擎就绪前的兜底：直板用户（绝大多数）
/// 冷启动即竖、全程零变化；宽屏形态（展开态/平板）由本闸运行时放开
/// ——横拿冷启动会先竖屏 splash 再转横，属主动横拿的可接受代价。
/// Android 12+ 分屏中系统可能忽略方向请求，本闸检测 multi-window 后
/// 主动交还，不做无谓设置。
class OrientationGate extends StatefulWidget {
  const OrientationGate({
    super.key,
    required this.child,
    this.multiWindowReader,
  });

  final Widget child;

  /// 分屏检测缝（默认走 companion/window 原生通道；测试注入）。
  final Future<bool> Function()? multiWindowReader;

  @override
  State<OrientationGate> createState() => _OrientationGateState();
}

class _OrientationGateState extends State<OrientationGate>
    with WidgetsBindingObserver {
  static const _windowChannel = MethodChannel('companion/window');

  /// 已应用的目标（同值不重设——didChangeMetrics 在旋转/键盘等高频
  /// 触发）。
  List<DeviceOrientation>? _applied;
  bool _hasApplied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 折叠/展开/分屏窗口变化都走这里；短边判定下旋转多为无操作。
    _pending = true;
    _refreshMultiWindow();
  }

  /// 尺寸或分屏态待重算标记：build 读到新约束时一并消化。
  bool _pending = true;
  bool _multiWindow = false;
  bool _multiWindowKnown = false;

  Future<bool> _queryMultiWindow() async {
    final reader = widget.multiWindowReader;
    try {
      if (reader != null) return await reader();
      final v = await _windowChannel.invokeMethod<bool>('isMultiWindow');
      return v ?? false;
    } catch (_) {
      // 通道未实现（iOS/测试环境）/读缝异常 → 按非分屏处理。
      return false;
    }
  }

  void _refreshMultiWindow() {
    _queryMultiWindow().then((v) {
      if (!mounted) return;
      if (_multiWindowKnown && _multiWindow == v) return;
      _multiWindow = v;
      _multiWindowKnown = true;
      // 分屏态翻转 → 立即重算应用（不等下一帧约束）。
      _apply();
    });
  }

  void _apply() {
    final targets = orientationTargetsFor(
      shortestSide: _shortestSide,
      multiWindow: _multiWindow,
    );
    final same = _hasApplied &&
        _applied != null &&
        listEquals(_applied, targets);
    if (same) return;
    _hasApplied = true;
    _applied = targets;
    SystemChrome.setPreferredOrientations(targets);
  }

  double _shortestSide = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final shortest = size.shortestSide;
        if (shortest != _shortestSide || _pending) {
          _shortestSide = shortest;
          _pending = false;
          // 首帧先按已知分屏态应用（冷启动直板=立刻锁竖，与 Manifest
          // 兜底一致）；分屏查询在途时结果回来再校正一次。
          _apply();
          if (!_multiWindowKnown) _refreshMultiWindow();
        }
        return widget.child;
      },
    );
  }
}
