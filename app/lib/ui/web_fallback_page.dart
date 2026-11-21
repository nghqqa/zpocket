import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:webview_flutter/webview_flutter.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../core/webview_errors.dart';

/// 官方网页版远控备用入口（阶段 4.2 最小版 / -8B，2026-10-29 批次）：
/// 零协议依赖的逃生舱——原生协议漂移/握手失败时仍可用官方 Web 远控。
///
/// marketing-claim-1 起参数化为通用「官方内嵌网页页」（奖励中心复用）：
/// - 目标默认=`https://zcode.z.ai/remote/v4/`（官方唯一正式手机远控入口，
///   refs web-remote-login 契约：`/remote/v4`（含尾斜杠）；不做深链直达
///   会话）。
/// - 导航白名单=[isWebFallbackNavAllowed]（zcode.z.ai 同源；其余阻止）。
/// - 登录态与 OAuth 登录 WebView 共享 Cookie/localStorage——本页**不做**
///   登录卫生清理（与登录页相反；已登录即直接可用，未登录走页面内
///   官方登录）。
/// - 关闭即返回原生：原生连接不拆不停（并行窗口语义，无恢复时序）。
class WebFallbackPage extends StatefulWidget {
  const WebFallbackPage({
    super.key,
    this.initialUri = 'https://zcode.z.ai/remote/v4/',
    this.title = '网页版远控（备用通道）',
    this.navAllowed = isWebFallbackNavAllowed,
    this.seedScriptProvider,
  });

  /// 初始加载地址（须过 [navAllowed] 白名单——首载同样校验，审查③中-8；
  /// 进页快照：后续变更忽略，刷新恒重载快照地址）。
  final String initialUri;

  /// AppBar 标题（中文源文案，Text 自动翻译；进页快照同上）。
  final String title;

  /// 导航白名单（默认官方域+OAuth 提供方）。
  final bool Function(Uri? uri) navAllowed;

  /// 官方域页面每次加载完成后执行的注入脚本提供器（marketing-claim-
  /// review-1：奖励中心凭据桥——奖励页 localStorage 停留在「上次 OAuth
  /// 登录的账号」，多账号/删号后会错配；注入当前账号 JWT 对齐官方桌面
  /// rewardsBridge 语义）。null=不注入（远控备用页默认）。
  final Future<String?> Function()? seedScriptProvider;

  /// 测试缝：无 WebView 平台通道的环境（widget 测试）禁用控制器创建。
  @visibleForTesting
  static bool debugDisableWebView = false;

  @override
  State<WebFallbackPage> createState() => _WebFallbackPageState();
}

/// 表格横滚注入脚本（rewards-table-fit-1，公开供测试钉住契约）：
/// 官方奖励中心表格按桌面宽度排版被卡片 overflow 硬裁；上一版 viewport
/// meta 注入在 webview_flutter_android 写死的 useWideViewPort(false) 下
/// 空转（真机截图实锤复核）。display:block 让表格自身成为滚动容器。
/// 幂等 id 守卫；head 样式跨 SPA 重渲染存活。
/// 注入作用域判定（审查轮2，纯函数供测试）：仅奖励中心路径——官方
/// 远控页（/remote/v4）的 Markdown 表格自带外层滚动视口+边缘阴影+隐藏
/// 滚动条（markdown-table.tsx:1235），全局注入会劫持其滚动容器、复活
/// 被官方刻意抑制的滚动条（UX 劣化）。
@visibleForTesting
bool shouldInjectTableFit(Uri? uri) {
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (host != 'zcode.z.ai' && !host.endsWith('.zcode.z.ai')) return false;
  return uri.path.toLowerCase().contains('rewards');
}

@visibleForTesting
const String kTableFitInjectScript =
    '(function(){if(document.getElementById("zp-table-fit"))return;'
    'var s=document.createElement("style");s.id="zp-table-fit";'
    's.textContent=".zp-table-scroll{overflow-x:auto;'
    '-webkit-overflow-scrolling:touch;max-width:100%}";'
    'document.head.appendChild(s);'
    // display:block 破坏 table 内部列宽分配（窄内容列不拉伸→右半空白，
    // 用户真机实锤）；改为把每张 table 包进横滚 div，保留原生 table 布局。
    'document.querySelectorAll("table").forEach(function(t){'
    'if(t.parentElement.classList.contains("zp-table-scroll"))return;'
    'var w=document.createElement("div");w.className="zp-table-scroll";'
    't.parentElement.insertBefore(w,t);w.appendChild(t)});})();';

/// 白名单判定（纯函数供测试）：官方域（含子域）、官方 OAuth 提供方
/// 页面与 WebView 内部协议放行。
bool isWebFallbackNavAllowed(Uri? uri) {
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'about' || scheme == 'data' || scheme == 'blob') return true;
  // 官方域强制 https——http 明文承载钓鱼面且
  // cookie 可被 MITM 注入。
  if (scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host == 'zcode.z.ai' || host.endsWith('.zcode.z.ai')) return true;
  // 官方登录整页跳 OAuth 提供方（refs webZaiOAuthConfig.ts:30）：
  // Z.AI=chat.z.ai，BigModel=bigmodel.cn。此前只放 zcode.z.ai，未登录
  // 用户在备用入口点登录会被 onNavigationRequest 拦死在下一页白屏。
  // 仍为精确主机匹配（子域伪装/其它域一律拒绝）。
  return host == 'chat.z.ai' || host == 'bigmodel.cn';
}

class _WebFallbackPageState extends State<WebFallbackPage> {
  WebViewController? _controller;
  String? _loadError;
  bool _controllerReady = false;

  /// 进页快照（审查③中-8/中-9）：initialUri/title/navAllowed 以首次构建
  /// 为准——后续变更（如 RewardsPage 随主题重建的 URL）一律忽略，杜绝
  /// 「显示旧地址、刷新跳新地址」的不一致；进页定档语义。
  late final Uri? _target = _validate(Uri.tryParse(widget.initialUri));
  late final bool Function(Uri?) _navAllowed = widget.navAllowed;
  late final String _titleSnapshot = widget.title;

  /// 首载/刷新统一校验：目标必须能解析且过白名单——泛化组件不假设调用
  /// 方传合法官方 URL（审查③中-8）。
  Uri? _validate(Uri? uri) =>
      uri != null && widget.navAllowed(uri) ? uri : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllerReady) return;
    _controllerReady = true;
    if (WebFallbackPage.debugDisableWebView) {
      _loadError = 'WebView unavailable in this environment';
      return;
    }
    final target = _target;
    if (target == null) {
      _loadError = 'invalid target uri';
      return;
    }
    final controller = WebViewController();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(context.colors.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final allowed = _navAllowed(Uri.tryParse(req.url));
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            // （复审）：新导航开始才清旧错误——Android 在主框架加载
            // 失败时同样会回调 onPageFinished（错误页），旧实现无条件清
            // 会把刚 set 的错误在几毫秒内抹掉（新提示几乎不可见）。
            if (_loadError != null && mounted) {
              setState(() => _loadError = null);
            }
          },
          onPageFinished: (url) {
            // rewards-table-fit-1（真机截图实锤复核）：官方奖励中心表格按
            // 桌面宽度排版（实测表宽≈卡片两倍）被卡片 overflow 硬裁——
            // viewport meta 注入在此 WebView 下空转（useWideViewPort 写死
            // false），改注入表格横滚 CSS；作用域限奖励页（审查轮2，
            // 见 shouldInjectTableFit 注释——远控页表格有自己的滚动方案）。
            if (shouldInjectTableFit(Uri.tryParse(url))) {
              unawaited(controller.runJavaScript(kTableFitInjectScript));
            }
            // 同一导航（错误页 finish）不清——错误浮层保留到用户发起
            // 下一次导航（刷新/点链接触发 onPageStarted）为止。
            //
            // marketing-claim-review-1：官方域页面完成时执行调用方注入
            // 脚本（奖励中心的官方凭据桥——rewardsBridge.ts 同款语义）。
            final seed = widget.seedScriptProvider;
            if (seed == null) return;
            final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
            if (host != 'zcode.z.ai' && !host.endsWith('.zcode.z.ai')) {
              return;
            }
            unawaited(
              seed()
                  .then((script) async {
                    if (script == null || script.isEmpty) return;
                    await controller.runJavaScript(script);
                  })
                  .catchError((_) {}),
            );
          },
          onWebResourceError: (e) {
            // 取消导航过滤平台化（早前批次，对齐 login_page）：
            // Android ERR_ABORTED(-1)/iOS NSURLErrorCancelled(-999) 都是
            // 跨域重定向常态；子资源错误一律不拦。纯函数见
            // core/webview_errors.dart。
            if (isFatalWebViewMainFrameError(e.errorCode, e.isForMainFrame) &&
                mounted) {
              setState(() => _loadError = '${e.errorCode}: ${e.description}');
            }
          },
        ),
      );
    _controller = controller;
    unawaited(
      controller.loadRequest(target).catchError((Object e) {
        if (mounted) setState(() => _loadError = '$e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(_titleSnapshot),
        actions: [
          if (controller != null)
            IconButton(
              key: const ValueKey('web-fallback-refresh'),
              icon: const Icon(Icons.refresh),
              // 刷新同样走快照地址+错误兜底（审查③中-8）。
              onPressed: () => unawaited(
                controller.loadRequest(_target!).catchError((Object e) {
                  if (mounted) setState(() => _loadError = '$e');
                }),
              ),
            ),
        ],
      ),
      body: controller == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('网页组件不可用：$_loadError'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.colors.foregroundSubtle),
                ),
              ),
            )
          : Stack(
              children: [
                WebViewWidget(controller: controller),
                if (_loadError != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: context.colors.card,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: context.colors.border),
                      ),
                      child: Text(
                        tr('加载异常：') + _loadError!,
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.warning,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
