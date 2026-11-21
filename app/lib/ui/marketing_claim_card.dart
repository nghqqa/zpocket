import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/remote_banner_image.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../state/marketing_controller.dart';
import '../transport/marketing_client.dart' show MarketingDelivery;

/// 首页领取卡（marketing-claim-1，；对抗审查修复批加固）。
///
/// 形态（用户拍板）：优先官方投放图（sha256 校验）；图不可得/加载中退
/// 文字头。宽窄两形态同卡（宽屏落左栏 232-320dp——操作行用 Flexible
/// 收缩，审查③高-1：固定 220 封顶+Spacer 在最窄档确定性溢出并把关闭
/// 钮挤出卡外）。
///
/// 订阅（审查②）：**空卡也订阅控制器**——拉取完成置卡时无须经由
/// 无关的 AppState 通知即可出现。
///
/// 图片（审查④高6/③中5）：campaign+资产双键控——投放或主题档（浅/深
/// 资产）变化即清旧字节重新取图；迟到回包按发起时的 campaign 校验，
/// 不串图。
class MarketingClaimCard extends StatefulWidget {
  const MarketingClaimCard({super.key, this.debugImageBytes});

  /// 视觉走查缝（debugFabHintForce 先例）：非空时跳过下载直接渲染
  /// 图片态（临时渲染采集用；生产恒 null）。
  @visibleForTesting
  final Uint8List? debugImageBytes;

  @override
  State<MarketingClaimCard> createState() => _MarketingClaimCardState();
}

class _MarketingClaimCardState extends State<MarketingClaimCard> {
  RemoteBannerImage? _imageFetcher;
  Uint8List? _imageBytes;
  String? _imageCampaignId;
  String? _imageAssetKey;
  bool _imageFailed = false;
  bool _imageLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final marketing = AppStateScope.of(context).marketing;
    if (marketing != null) {
      // 失败退避/每账号闸/账号节流在控制器内——非 force 触发零成本。
      unawaited(marketing.ensurePulled());
    }
  }

  @override
  void dispose() {
    _imageFetcher?.close();
    super.dispose();
  }

  /// 投放或主题资产档变化则重取图；迟到回包按 campaign 丢弃。
  void _maybeLoadImage(MarketingCard card, Brightness brightness) {
    final id = card.delivery.campaignId;
    final asset = brightness == Brightness.dark
        ? (card.delivery.darkImage ?? card.delivery.image)
        : (card.delivery.image ?? card.delivery.darkImage);
    final assetKey = asset?.src.toString();

    // 视觉走查缝：注入字节直接进图片态。
    final injected = widget.debugImageBytes;
    if (injected != null) {
      if (_imageCampaignId != id) {
        _imageCampaignId = id;
        _imageAssetKey = assetKey;
        _imageBytes = injected;
      }
      return;
    }

    // campaign 或资产档变化：全清重取（审查④高6：换投放不清旧字节会
    // 串图；主题换档此前永不重取 darkImage）。
    if (_imageCampaignId != id || _imageAssetKey != assetKey) {
      _imageCampaignId = id;
      _imageAssetKey = assetKey;
      _imageBytes = null;
      _imageFailed = false;
      _imageLoading = false;
    }
    if (asset == null) {
      _imageFailed = true;
      return;
    }
    if (_imageBytes != null || _imageFailed || _imageLoading) return;
    _imageLoading = true;
    final fetcher = _imageFetcher ??= RemoteBannerImage();
    unawaited(
      fetcher.fetch(cacheKey: id, src: asset.src, sha256Hex: asset.sha256).then(
        (bytes) {
          // 竞态守卫：回包时投放已换（或组件已卸载）则丢弃。
          if (!mounted || _imageCampaignId != id) return;
          setState(() {
            _imageBytes = bytes;
            _imageFailed = bytes == null;
            _imageLoading = false;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final marketing = AppStateScope.of(context).marketing;
    if (marketing == null) return const SizedBox.shrink();
    // 空卡也订阅（审查②）：拉取完成置卡→本 builder 重建→卡片出现，
    // 不依赖无关的 AppState 通知。
    return ListenableBuilder(
      listenable: marketing,
      builder: (context, _) {
        final current = marketing.card;
        if (current == null) return const SizedBox.shrink();
        // 收起态（marketing-claim-collapse-1）：整条薄栏，点击展开；
        // 「晚点领」与 dismiss（本会话不再提醒）分职。AnimatedSize
        // （审查①）：收起/展开 80-184dp 高度差走 160ms 过渡，下方
        // 任务列表不再瞬移。
        final Widget child;
        if (marketing.isCollapsed) {
          child = _buildCollapsedBar(context, marketing, current);
        } else {
          _maybeLoadImage(current, Theme.of(context).brightness);
          child = _buildCard(context, marketing, current);
        }
        return AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: child,
        );
      },
    );
  }

  /// 收起条（48dp 单行）：整条可点展开 + 关闭（dismiss 仍可达）。
  /// 审查①/M3/：窄档（屏宽<300dp）隐藏礼物图标+短文案「待领取
  /// 福利」；Semantics(button) 补无障碍；投放 title 可用时优先展示
  /// （与完整卡文字头同规则，translate:false 保原文）。
  Widget _buildCollapsedBar(
    BuildContext context,
    MarketingController marketing,
    MarketingCard card,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: context.colors.card,
        elevation: 0,
        // 与完整卡同族：同圆角+1px 描边（视觉快审必修——收起条无满宽
        // 图片，shape side 直接生效，无需完整卡的 Stack 覆盖层）。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: tr('待领取福利'),
                  hint: tr('展开'),
                  child: InkWell(
                    key: const ValueKey('marketing-claim-collapsed'),
                    onTap: marketing.expand,
                    // minHeight 进 InkWell 子级——命中区=整条 48dp
                    // （InkWell 尺寸随子级，外层 SizedBox 不传导 hit box）。
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Builder(
                          builder: (context) {
                            final narrow =
                                MediaQuery.sizeOf(context).width < 300;
                            final serverTitle = (card.delivery.title ?? '')
                                .trim();
                            return Row(
                              children: [
                                // 审查③：收起态藏错误行——行首图标换
                                // warning 色错误指示（展开后错误行完整
                                // 保留）。窄档隐藏礼物图标（审查①），
                                // 错误指示恒保留。
                                if (!narrow || marketing.errorKind != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(
                                      marketing.errorKind == null
                                          ? Icons.card_giftcard_outlined
                                          : Icons.error_outline,
                                      size: 18,
                                      color: marketing.errorKind == null
                                          ? context.colors.brandAccent
                                          : context.colors.warning,
                                    ),
                                  ),
                                Expanded(
                                  child: Text(
                                    serverTitle.isNotEmpty && !narrow
                                        ? serverTitle
                                        : tr(narrow ? '待领取福利' : '官方福利待领取'),
                                    translate: serverTitle.isNotEmpty && !narrow
                                        ? false
                                        : true,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.expand_more,
                                  size: 18,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  key: const ValueKey('marketing-claim-collapsed-dismiss'),
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: context.colors.foregroundSubtlest,
                  ),
                  tooltip: tr('关闭'),
                  onPressed: marketing.claiming
                      ? null
                      : () => unawaited(
                          _dismissWithUndo(context, marketing, card),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// dismiss + 撤销 SnackBar（审查①M2：整条展开可逆、X 不可逆，误触
  /// 代价不对称——撤销恢复卡片；项目既有先例=任务归档撤销）。
  Future<void> _dismissWithUndo(
    BuildContext context,
    MarketingController marketing,
    MarketingCard card,
  ) async {
    await marketing.dismiss(card);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('已关闭，本会话内不再提醒')),
        // 本 SDK 带 action 的 SnackBar 默认 persist=true 永不过期
        //（snack_bar.dart:303）——显式关闭+4s（同批归档提示真因修复）。
        duration: const Duration(seconds: 4),
        persist: false,
        action: SnackBarAction(
          label: tr('撤销'),
          onPressed: marketing.undoDismiss,
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    MarketingController marketing,
    MarketingCard card,
  ) {
    final delivery = card.delivery;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: context.colors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_imageBytes != null)
                  // 审查必修②：字节到达≠首帧就绪——解码完成前保持文字头
                  // （frame==null），避免高度跳变推动任务列表；contain+
                  // 限高防竖版图占满半屏；cacheWidth 封顶解码尺寸防解压
                  // 炸弹（审查③中-4：≤2MiB 压缩字节可声明 2 万像素宽）。
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: Image.memory(
                      _imageBytes!,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      cacheWidth: 1280,
                      frameBuilder: (context, child, frame, wasSync) =>
                          frame == null
                          ? _textHeader(context, delivery)
                          : child,
                      errorBuilder: (_, _, _) => _textHeader(context, delivery),
                    ),
                  )
                else
                  _textHeader(context, delivery),
                if (marketing.errorKind != null) _errorRow(context, marketing),
                _actionRow(context, marketing, card),
              ],
            ),
            // 审查建议：描边画在图片之上（Material shape border 会被
            // 顶部满宽图片盖掉，浅色投放图会丢卡轮廓）。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.colors.border),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文字头（图片不可得/加载中的兜底形态）。投放 title/description 是
  /// 服务端数据（按 X-Client-Language 已在服务端本地化）——
  /// translate:false 保原文，不进词表。
  Widget _textHeader(BuildContext context, MarketingDelivery delivery) {
    final title = (delivery.title ?? '').trim().isNotEmpty
        ? delivery.title!.trim()
        : null;
    final desc = (delivery.description ?? '').trim().isNotEmpty
        ? delivery.description!.trim()
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.card_giftcard_outlined,
            size: 20,
            color: context.colors.brandAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(
                    title,
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foreground,
                    ),
                  )
                else
                  Text(
                    '官方福利',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foreground,
                    ),
                  ),
                const SizedBox(height: 2),
                if (desc != null)
                  Text(
                    desc,
                    translate: false,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  )
                else
                  Text(
                    '领取您的专属福利',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorRow(BuildContext context, MarketingController marketing) {
    final String fallback;
    final String? server;
    switch (marketing.errorKind) {
      case MarketingClaimError.server:
        server = (marketing.serverErrorMessage ?? '').trim();
        fallback = tr('领取失败，请稍后重试。');
      case MarketingClaimError.authRequired:
        server = null;
        fallback = tr('账号凭据已失效，请重新登录后再领取。');
      case MarketingClaimError.uncertain:
        server = null;
        fallback = tr('领取结果未知，请稍后重试。');
      case null:
        return const SizedBox.shrink();
    }
    // 服务端文案是已本地化数据——保原文不经词表二次改写（审查③低-1）；
    // 本地兜底走翻译。文案已在客户端截断 ≤300 字符。
    final text = server != null && server.isNotEmpty ? server : fallback;
    final isServer = server != null && server.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 14, color: context.colors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              translate: !isServer,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    BuildContext context,
    MarketingController marketing,
    MarketingCard card,
  ) {
    final delivery = card.delivery;
    // 按钮文案取自 claim 按钮自身（客户端解析已绑定）；空=本地回退
    // 「领取」（可翻译——审查③中-10：回退串必须走词表，服务端串保原文）。
    final serverLabel = (delivery.buttonText ?? '').trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 审查①：单行档固定项（8+48+48）+行内距后，232dp 卡只剩
        // 76dp 给主 CTA——两字被裁/busy 缩到 0.4x。窄卡（<280dp，即
        // 宽屏左栏最窄两档）改两行：领取独占一行（≈180dp），收起/关闭
        // 右对齐次行。
        final twoLine = constraints.maxWidth < 280;
        final claim = _claimButton(
          context,
          marketing,
          serverLabel,
          expanded: twoLine,
        );
        final trailing = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 收起（marketing-claim-collapse-1）：「晚点领」——仅收为薄
            // 栏，不 suppress 不上报；claiming 在途禁用（防领取中视图
            // 跳变）。
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                key: const ValueKey('marketing-claim-collapse'),
                icon: Icon(
                  Icons.expand_less,
                  size: 20,
                  // 审查①/：功能唯一入口提一档对比度；claiming 禁用
                  // 态再降一档给出视觉反馈。
                  color: marketing.claiming
                      ? context.colors.foregroundSubtlest
                      : context.colors.foregroundSubtle,
                ),
                tooltip: tr('收起'),
                onPressed: marketing.claiming
                    ? null
                    : () => marketing.collapse(card),
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: context.colors.foregroundSubtlest,
                ),
                tooltip: tr('关闭'),
                onPressed: marketing.claiming
                    ? null
                    : () =>
                          unawaited(_dismissWithUndo(context, marketing, card)),
              ),
            ),
          ],
        );
        if (twoLine) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 4, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: claim,
                ),
                Align(alignment: Alignment.centerRight, child: trailing),
              ],
            ),
          );
        }
        return Padding(
          // 与文字头内容线对齐（16dp）；关闭钮 48dp 槽含自身内距。
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: Row(
            children: [
              // release-108 走查：Expanded 的弹性区必须整体占满，
              // 内部 Align 左对齐领取钮，尾部收起/关闭才自然贴右；
              // 窄档溢出仍由弹性区承担，长文案不顶死关闭钮。
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: claim,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        );
      },
    );
  }

  Widget _claimButton(
    BuildContext context,
    MarketingController marketing,
    String serverLabel, {
    required bool expanded,
  }) {
    final button = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: context.colors.brandAccent,
        foregroundColor: context.colors.onBrandAccent,
      ),
      onPressed: marketing.claiming ? null : () => _claim(context, marketing),
      child: marketing.claiming
          ? FittedBox(
              // 审查①：两行档 busy 独占整行不再压缩；单行档此兜底
              // 仅防极端（预算 ≥124dp）。
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(tr('领取中…')),
                ],
              ),
            )
          : serverLabel.isEmpty
          // 审查①：回退串补 ellipsis（原仅 maxLines）。
          ? const Text('领取', maxLines: 1, overflow: TextOverflow.ellipsis)
          : Text(
              serverLabel,
              translate: false,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    );
    if (expanded) {
      return SizedBox(width: double.infinity, child: button);
    }
    return button;
  }

  Future<void> _claim(
    BuildContext context,
    MarketingController marketing,
  ) async {
    // marketing-reminder-1：纯提醒语义——投递可见+明确引导电脑端领取。
    // 不在本端发起领取、不跳奖励中心；点按钮=弹电脑端领取提醒。
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('请在电脑端打开 ZCode，点击左下角卡片领取'))));
  }
}
