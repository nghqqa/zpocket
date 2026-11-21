// 后台 Bash 输出详情页（bg-bash-output-1，2026-11-20）：
// 官方 v4/conversation/backgroundBashOutput 只读查询（固定尾读 8KiB、
// existing-only 不冷恢复、零模型请求）的手机消费页。交互合同对齐官方
// docs/background-bash-output-details.md：打开立即查询→运行中每秒轮询
// （最多一个在途）→终态确认后再读一次尾部然后停止；退后台/被上层路由
// 覆盖停止轮询并丢弃迟到结果（epoch 守卫）；读取失败保留上次内容并提供
// 重试（BGV05）；详情不含停止按钮（取消沿用后台工作列表入口）；不展示
// 尾窗省略提示（官方口径）。跟随底部=滚动位置判定（上滚 48px 冻结、
// 回到底部 8px 容差恢复），不做悬浮箭头（裁剪留白）。
import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import 'app_widgets.dart' show AppLoading, CopyIconButton;

/// 查询响应 kind='output' 的六态人话（与 backgroundWorks 列表四态不同源，
/// 官方 backgroundBashOutputSchema.status 枚举）。
String bashOutputStatusLabel(String status) => switch (status) {
  'running' => '执行中',
  'completed' => '已完成',
  'failed' => '失败',
  'timed_out' => '已超时',
  'cancelled' => '已取消',
  'spawn_error' => '启动失败',
  _ => status,
};

/// 终态判定：running 之外全部终态。
bool bashOutputTerminal(String status) => status != 'running';

/// 错误态三联人话（unavailable=执行记录不在内存，如子会话冷回收后；
/// unsupported=旧桌面无此查询方法；read_failed=读文件失败）。
String bashOutputErrorLabel(String kind) => switch (kind) {
  'unavailable' => '输出暂不可用（任务记录不在内存中）',
  'unsupported' => '当前桌面版本不支持查看输出',
  _ => '读取输出失败',
};

/// 响应归类：kind='output' 返回强转 Map，其余（错误态/非 Map）返回 null。
Map<String, dynamic>? bashOutputResultOf(dynamic res) =>
    res is Map && res['kind'] == 'output' ? res.cast<String, dynamic>() : null;

class BackgroundBashOutputPage extends StatefulWidget {
  final String sessionId;
  final String workId;
  final String title;

  /// 查询回调（接线=AppState.backgroundBashOutput；测试注入假队列）。
  final Future<dynamic> Function(String sessionId, String workId) fetch;

  const BackgroundBashOutputPage({
    super.key,
    required this.sessionId,
    required this.workId,
    required this.title,
    required this.fetch,
  });

  @override
  State<BackgroundBashOutputPage> createState() =>
      _BackgroundBashOutputPageState();
}

class _BackgroundBashOutputPageState extends State<BackgroundBashOutputPage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _result;
  String? _error;
  bool _inFlight = false;

  /// 终态确认后的补读只做一次（官方合同「终态确认后读一次尾部」）。
  bool _finalReadDone = false;

  /// 轮询代际：退后台/重试时自增，迟到结果按代丢弃。
  int _epoch = 0;

  /// 回前台时在途请求未归的恢复查询挂起标记（U1：丢弃出口续发）。
  bool _resumeFetchPending = false;
  Timer? _timer;
  final ScrollController _scroll = ScrollController();
  bool _followBottom = true;

  static const _pollInterval = Duration(seconds: 1);
  static const _fetchTimeout = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (_scroll.offset < max - 48) {
      _followBottom = false;
    } else if (_scroll.offset >= max - 8) {
      _followBottom = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 回前台（对抗审查修复 U1/U2）：官方合同「重新激活立即查询」——
      // 运行中/首载未归/终态都补查一次（终态查询即停不复活轮询）；唯一
      // 不补的是「首载即失败」态（等用户手动重试）。在途旧代请求会被
      // 代际守卫丢弃，挂待发标记在其丢弃出口续发，否则单在途守卫会吞
      // 掉恢复查询、轮询永久停摆。
      if (_result == null && _error != null) return;
      if (_inFlight) {
        _resumeFetchPending = true;
      } else {
        _fetch();
      }
    } else if (state == AppLifecycleState.paused) {
      _epoch++;
      _stopTimer();
    }
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(_pollInterval, (_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      _fetch();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _fetch() async {
    if (_inFlight) return;
    _inFlight = true;
    final epoch = _epoch;
    Map<String, dynamic>? output;
    String? kindError;
    var failed = false;
    try {
      final res = await widget
          .fetch(widget.sessionId, widget.workId)
          .timeout(_fetchTimeout);
      if (mounted && epoch == _epoch) {
        output = bashOutputResultOf(res);
        if (output == null) {
          kindError = bashOutputErrorLabel(res is Map ? '${res['kind']}' : '');
        }
      }
    } catch (_) {
      if (mounted && epoch == _epoch) failed = true;
    } finally {
      // 先释放在途闸再应用状态——终态补读（_afterOutput→_fetch）才不会被
      // 自己的单在途守卫吞掉。
      _inFlight = false;
    }
    if (!mounted || epoch != _epoch) {
      // 对抗审查修复 U1：旧代结果丢弃出口续发回前台挂起的恢复查询。
      if (mounted && _resumeFetchPending) {
        _resumeFetchPending = false;
        scheduleMicrotask(_fetch);
      }
      return;
    }
    // 审查轮2 ：有效代结果路径同样消费挂起标记——防残留标记在未来
    // 的丢弃出口多续发一次查询。
    if (_resumeFetchPending) _resumeFetchPending = false;
    if (output != null) {
      setState(() {
        _result = output;
        _error = null;
      });
      _afterOutput(output);
    } else if (kindError != null) {
      // BGV05：读取失败保留最后成功内容，停止轮询并提供重试。
      _stopTimer();
      setState(() {
        _error = kindError;
      });
    } else if (failed) {
      _stopTimer();
      setState(() {
        _error = _result == null ? '读取输出失败' : '读取输出失败，已保留上次内容';
      });
    }
  }

  void _afterOutput(Map<String, dynamic> output) {
    final status = output['status'];
    if (status is String && !bashOutputTerminal(status)) {
      _ensureTimer();
      _jumpToBottomIfFollowing();
      return;
    }
    // 终态：确认后再读一次尾部，然后停轮询。补读的尾窗可能比确认帧长
    // （对抗审查修复 U6）——跟随态同样回底。
    _stopTimer();
    _jumpToBottomIfFollowing();
    if (!_finalReadDone) {
      _finalReadDone = true;
      unawaited(_fetch());
    }
  }

  void _jumpToBottomIfFollowing() {
    if (!_followBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _retry() {
    _finalReadDone = false;
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (result != null)
            CopyIconButton(
              key: const ValueKey('bash-output-copy'),
              text: '${result['output'] ?? ''}',
              tooltip: '复制输出',
              snackText: '输出已复制',
            ),
        ],
      ),
      body: result == null && _error == null
          ? const Center(child: AppLoading('正在加载…'))
          : result == null
          // 首载即失败：居中空态（视觉复核必修——顶部孤条+700px 空区
          // 像没加载出来；重试钮沿用 _retrySubscribe 的 OutlinedButton
          // 先例）。
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 32,
                    color: context.colors.destructive,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error ?? '',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('bash-output-retry'),
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _statusRow(context, result),
                if (_error != null) _errorRow(context),
                // Flexible：内容少时卡片贴合内容不撑满（视觉复核建议），
                // 内容多时占满剩余高度滚动。
                Flexible(child: _outputArea(context, result)),
              ],
            ),
    );
  }

  /// 顶部状态条：状态靠左、完整文件路径靠右（官方口径，同为弱化色）。
  Widget _statusRow(BuildContext context, Map<String, dynamic> result) {
    final status = '${result['status'] ?? ''}';
    final color = switch (status) {
      'running' => context.colors.running,
      'failed' || 'timed_out' || 'spawn_error' => context.colors.destructive,
      _ => context.colors.foregroundSubtle,
    };
    final outputPath = '${result['outputPath'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Text(
            bashOutputStatusLabel(status),
            style: TextStyle(fontSize: AppType.uiCaption, color: color),
          ),
          if (outputPath.isNotEmpty) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                outputPath,
                translate: false,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _errorRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _error ?? '',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.destructive,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('bash-output-retry'),
            onPressed: _retry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _outputArea(BuildContext context, Map<String, dynamic> result) {
    final text = '${result['output'] ?? ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.block),
        border: Border.all(color: context.colors.border),
      ),
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.all(12),
        child: text.isEmpty
            ? Text(
                '没有输出。',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              )
            : SelectableText(
                text,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  fontFamily: 'monospace',
                  // 输出正文=本页唯一主体内容，深浅主题统一 foregroundSubtle
                  // （视觉复核必修：浅色 45% 档仅 2.69:1 正文发灰费眼）。
                  color: context.colors.foregroundSubtle,
                  height: 1.45,
                ),
              ),
      ),
    );
  }
}
