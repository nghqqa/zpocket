import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'protocol_drift.dart';
import 'relay_v2.dart' show RelayV2AuthRequired, relayV2MaxHttpResponseBytes;

/// 官方营销投放直连客户端（marketing-claim-1，；marketing-reminder-1
/// 起收敛为 touch 投放展示+电脑端提醒——手机端只读，不在本端领取）。
///
/// 契约出处（官方最新源码快照 3.18.2 源码，已核实到行）：
/// - 投放查询：`GET /api/v1/marketing/touch?seq=N`，headers
///   `X-Device-Mid`(UUID)/`X-Client-Language`/`X-ZCode-App-Version`/
///   `Authorization`（可选——本应用只在有账号时拉取，故实现为必填）
///   （marketingTouchService.ts:42-47、query :53-54）。
///   信封 `{code:0, data:{server_time(秒), language, deliveries[]}}`；
///   单条坏投放丢弃不影响其余（marketingTouch.ts parseMarketingTouchResponse）；
///   deliveries>32 官方 zod max(32) 拒整个响应——同款拒绝不截断（:153）。
/// - 行为上报：`POST /api/v1/marketing/touch/action`，body
///   `{campaign_id, action_type: confirm|cancel}`，成功=code=0（仅分析用）。
/// - HTTP 栈对齐官方 readApiJson（apiJson.ts:74-95）：**非 2xx 一律抛错
///   不读业务字段**；redirect:error（touch/action）=重定向按传输失败。
///
/// 与 [RelayV2Api] 的关系：不复用其 `_request`——按端点组头的信封语义
/// 不同，且该类文档限定终端两只读调用。4MiB 上限沿用 relay 常量（官方
/// touch 理论极值可超此值，属客户端更严约束）；401 语义复用
/// [RelayV2AuthRequired]。
class MarketingApiClient {
  static const touchPath = '/api/v1/marketing/touch';
  static const touchActionPath = '/api/v1/marketing/touch/action';

  /// 官方投放 deliveries 上限（marketingTouch.ts :153 z.array.max(32)——
  /// 超限整个信封非法，不截断）。
  static const maxDeliveries = 32;

  final Uri origin;
  final Future<String?> Function() jwtProvider;

  /// 本机设备标识（官方 X-Device-Mid，UUID）——由调用方持久化生成后注入。
  final String deviceMid;

  /// 界面语言（官方 X-Client-Language，须为真实界面语言）。
  final String locale;

  /// 本应用版本号（官方 X-ZCode-App-Version）。
  final String appVersion;

  /// 平台标识（官方 `${platform}-${arch}` 自由串；本应用只报系统名，
  /// 不伪称架构—— 留痕取舍）。
  final String platform;

  final Duration timeout;
  final void Function(String line)? onLog;

  io.HttpClient? _httpClient;
  io.HttpClient get _client =>
      _httpClient ??= (io.HttpClient()..connectionTimeout = timeout);

  /// 投放查询序号（官方 bootRequestSeq 语义：进程启动内单调递增——
  /// 模块级而非实例级；控制器每次拉取新建客户端实例，实例级会让 seq
  /// 恒归零失去防抖意义）。
  static int _touchSeq = 0;

  MarketingApiClient({
    required this.origin,
    required this.jwtProvider,
    required this.deviceMid,
    this.locale = 'zh-CN',
    this.appVersion = '0.0.0',
    this.platform = 'android',
    this.timeout = const Duration(seconds: 15),
    this.onLog,
  });

  void close() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  /// 拉取当前账号的营销投放快照。
  ///
  /// 抛 [RelayV2AuthRequired]（401/JWT 缺失）或 [MarketingUnavailable]；
  /// 单条坏投放只静默丢弃（官方同款），信封级缺失走协议哨兵后抛错。
  Future<MarketingTouchSnapshot> touch() async {
    final seq = _touchSeq++;
    final envelope = await _request('GET', touchPath, query: {'seq': '$seq'});
    final data = envelope['data'];
    if (envelope['code'] != 0 || data is! Map) {
      noteProtocolDrift('marketing.touch', envelope, ['code', 'data']);
      throw MarketingUnavailable(
        'touch 信封非 code=0/data 对象',
        retryable: envelope['code'] == 0,
      );
    }
    noteProtocolDrift('marketing.touch', data, const [
      'server_time',
      'language',
      'deliveries',
    ], onLog: onLog == null ? null : (line) => onLog?.call(line));
    final serverTime = data['server_time'];
    final rawDeliveries = data['deliveries'];
    // marketing-diag-1：真机无卡取证——成功路径也打响应摘要（原始
    // deliveries 截断 800 字符；无 PII，campaign/plan id 属服务端数据）。
    // ignore: avoid_print
    print(
      '[marketing] touch seq=$seq lang=${data['language']} '
      'deliveries=${rawDeliveries is List ? rawDeliveries.length : '非List'} '
      'raw=${_clip(rawDeliveries)}',
    );
    if (serverTime is! num || rawDeliveries is! List) {
      throw const MarketingUnavailable(
        'touch data 缺 server_time/deliveries',
        retryable: false,
      );
    }
    // 官方 z.array().max(32)：超限=整个信封非法（不静默截断——协议
    // 漂移信号必须上浮，审查）。
    if (rawDeliveries.length > maxDeliveries) {
      throw MarketingUnavailable(
        'touch deliveries ${rawDeliveries.length} 超官方上限 $maxDeliveries',
        retryable: false,
      );
    }
    // 官方 server_time 为秒（parseMarketingTouchResponse ×1000）。
    final deliveries = <MarketingDelivery>[];
    final positions = <String>{};
    var dropped = 0;
    for (final raw in rawDeliveries) {
      final parsed = _parseDelivery(raw);
      if (parsed == null) {
        dropped++;
        // ignore: avoid_print
        print('[marketing] 投放被拒收：${_clip(raw)}');
        continue;
      }
      // 官方按 resource_position 去重只留首条（positions Set）。
      if (!positions.add(parsed.position)) {
        dropped++;
        continue;
      }
      deliveries.add(parsed);
    }
    // ignore: avoid_print
    print('[marketing] touch 解析完成 保留=${deliveries.length} 丢弃=$dropped');
    return MarketingTouchSnapshot(
      serverTimeMs: (serverTime * 1000).round(),
      language: '${data['language'] ?? ''}',
      deliveries: deliveries,
    );
  }

  /// 行为上报（confirm/cancel）。非 0 视为失败——调用方 fire-and-forget，
  /// 失败仅记录，不影响领取结果。
  Future<void> reportAction(String campaignId, {required bool confirm}) async {
    final envelope = await _request(
      'POST',
      touchActionPath,
      body: {
        'campaign_id': campaignId,
        'action_type': confirm ? 'confirm' : 'cancel',
      },
    );
    if (envelope['code'] != 0) {
      throw MarketingUnavailable(
        'action 上报 code=${envelope['code']}',
        retryable: true,
      );
    }
  }

  /// 诊断打点截断（原始投放 JSON 片段）。
  static String _clip(dynamic raw) {
    final text = raw.toString();
    return text.length > 800 ? text.substring(0, 800) : text;
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final jwt = await jwtProvider();
    if (jwt == null || jwt.isEmpty) throw const RelayV2AuthRequired();
    final client = _client;
    io.HttpClientRequest? req;
    try {
      final target = query == null
          ? origin.replace(path: path)
          : origin.replace(path: path, queryParameters: query);
      req = await client.openUrl(method, target);
      if (jwt.isNotEmpty) {
        req.headers.set(io.HttpHeaders.authorizationHeader, 'Bearer $jwt');
      }
      if (body != null) {
        req.headers.set(io.HttpHeaders.contentTypeHeader, 'application/json');
      }
      // 按端点组头（审查 对齐官方）：Device-Mid/Client-Language/
      // App-Version（marketingTouchService.ts:42-47）。
      req.headers.set('X-Device-Mid', deviceMid);
      req.headers.set('X-Client-Language', locale);
      req.headers.set('X-ZCode-App-Version', appVersion);
      // 官方 touch/action redirect:"error"（:59/:80）→ 不跟随，重定向
      // 按传输失败处理。
      req.followRedirects = false;
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close().timeout(timeout);
      if (res.statusCode == 401) {
        unawaited(res.drain<void>().catchError((_) {}));
        throw const RelayV2AuthRequired();
      }
      // 审查 ：非 2xx 一律不读业务字段（官方 apiJson !response.ok 即
      // 抛错）；3xx 在 followRedirects=false 下同走此分支（touch/action
      // 对齐官方 redirect:error=瞬态失败）。
      if (res.statusCode < 200 || res.statusCode >= 300) {
        unawaited(res.drain<void>().catchError((_) {}));
        throw MarketingUnavailable(
          'HTTP $path 状态 ${res.statusCode}',
          retryable: true,
        );
      }
      // 审查 ：body 收集整体限时——回完头后停 body 的对端会永久挂起
      // 请求；超时即 abort。
      final bodyBytes = BytesBuilder(copy: false);
      try {
        await (() async {
          await for (final chunk in res) {
            bodyBytes.add(chunk);
            if (bodyBytes.length > relayV2MaxHttpResponseBytes) {
              throw MarketingUnavailable(
                'HTTP $path 响应体超 '
                '${relayV2MaxHttpResponseBytes ~/ (1024 * 1024)}MiB 上限',
                retryable: false,
              );
            }
          }
        })().timeout(timeout);
      } on TimeoutException {
        req.abort();
        throw MarketingUnavailable('HTTP $path 响应体超时', retryable: true);
      }
      final text = utf8.decode(bodyBytes.takeBytes(), allowMalformed: true);
      if (text.isEmpty) {
        throw MarketingUnavailable('HTTP $path 空响应体', retryable: false);
      }
      final dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        // 审查 ：非法 JSON 归一为协议不可用，不裸抛 FormatException。
        throw MarketingUnavailable('HTTP $path 响应非合法 JSON', retryable: false);
      }
      if (decoded is! Map) {
        throw MarketingUnavailable('HTTP $path 响应非 JSON 对象', retryable: false);
      }
      return decoded;
    } on TimeoutException {
      req?.abort();
      throw MarketingUnavailable('HTTP $path 超时', retryable: true);
    } on io.SocketException catch (e) {
      throw MarketingUnavailable('HTTP $path 网络不可达: $e', retryable: true);
    } on io.HttpException catch (e) {
      throw MarketingUnavailable('HTTP $path 传输失败: $e', retryable: true);
    }
  }
}

/// 营销接口不可用（网络/服务端）。`retryable=false` 表示重试无意义
/// （体超限/空响应/超限 deliveries 等）。
class MarketingUnavailable implements Exception {
  final String message;
  final bool retryable;
  const MarketingUnavailable(this.message, {this.retryable = true});
  @override
  String toString() => 'MarketingUnavailable($message, retryable=$retryable)';
}

/// 一条营销投放的手机侧投影（v1 只保留领取动作所需的字段）。
///
/// 官方 banner/popup 双形态在此收敛：position 保留原值仅供诊断；图片
/// 资产（banner.background / popup.hero 的 image 变体）统一为
/// [image]/[darkImage]，video/bundle 变体不取（文字卡兜底）。
///
/// [buttonText] 与 [claimPlanId] **取自同一个 claim 按钮**（审查 ：
/// 官方每按钮自带 text+action，跨按钮拼接会出现「文案说了解详情、
/// 点击却领取」）——claim 按钮文本为空时 buttonText=null（UI 用本地
/// 回退文案并可翻译，服务端文案保持原文）。
class MarketingDelivery {
  final String campaignId;
  final int priority;
  final String position; // 'banner' | 'popup'
  final String? title; // popup.title（plaintext）；banner 无结构化标题
  final String? description; // popup.description（plaintext）
  final MarketingAsset? image;
  final MarketingAsset? darkImage;
  final String? buttonText; // claim 按钮自身的纯文本（空=缺失）
  final String? claimPlanId; // claim 按钮的 plan_id
  const MarketingDelivery({
    required this.campaignId,
    required this.priority,
    required this.position,
    this.title,
    this.description,
    this.image,
    this.darkImage,
    this.buttonText,
    this.claimPlanId,
  });

  /// 是否可作为领取卡展示（v1 范围=带 claim 按钮的投放）。
  bool get claimable => claimPlanId != null && claimPlanId!.isNotEmpty;
}

class MarketingAsset {
  final Uri src;
  final String sha256;
  const MarketingAsset(this.src, this.sha256);
}

class MarketingTouchSnapshot {
  /// 服务端时间（毫秒；官方 server_time 为秒，解析时已 ×1000）。
  final int serverTimeMs;
  final String language;
  final List<MarketingDelivery> deliveries;
  const MarketingTouchSnapshot({
    required this.serverTimeMs,
    required this.language,
    required this.deliveries,
  });
}

/// 解析单条投放；不合法返回 null（官方 safeParse 丢弃语义）。
/// 校验口径对齐 marketingTouch.ts 的 zod（审查 M2/M3// 收紧）：
/// - campaign_id 1-128、priority 0-100（整值 double 归一为 int）；
/// - banner：≤2 按钮且 close ≤1 且**非 close ≤1**（官方 refine :136-140）、
/// background 放宽为可缺省（官方必填；文字卡兜底属有意放宽，决策记录 留痕）；
/// - popup：title/description/buttons(≤4) 必在场；
/// - 按钮动作 claim_zcode_plan 须带 plan_id；action.type 必须是官方五类
///   之一（close/open_url/claim_zcode_plan/navigate/copy_text），否则整条
///   丢弃（防未知动作静默执行领取语义）；
/// - text.content 必须是 String 且 ≤20000；
/// - asset src ≤4096、禁 userinfo、host 非空（官方 :6-18）。
MarketingDelivery? _parseDelivery(dynamic raw) {
  if (raw is! Map) return null;
  final campaignId = '${raw['campaign_id'] ?? ''}'.trim();
  if (campaignId.isEmpty || campaignId.length > 128) return null;
  final priority = _asInt(raw['priority']);
  if (priority == null || priority < 0 || priority > 100) return null;
  final position = '${raw['resource_position'] ?? ''}';
  final Map? shape;
  switch (position) {
    case 'banner':
      shape = raw['banner'] is Map ? raw['banner'] as Map : null;
    case 'popup':
      shape = raw['popup'] is Map ? raw['popup'] as Map : null;
    default:
      return null;
  }
  if (shape == null) return null;

  final rawButtons = shape['buttons'];
  if (rawButtons is! List ||
      rawButtons.length > (position == 'banner' ? 2 : 4)) {
    return null;
  }
  String? buttonText;
  String? claimPlanId;
  var closeButtons = 0;
  var nonCloseButtons = 0;
  for (final b in rawButtons) {
    if (b is! Map) return null;
    final action = b['action'];
    final type = action is Map ? '${action['type']}' : '';
    final text = b['text'];
    // 官方按钮 text 对象必在场（close 也一样，:80-86）。
    if (text is! Map) return null;
    final content = text['content'];
    if (content is! String || content.length > 20000) return null;
    if (type == 'close') {
      closeButtons++;
      if (closeButtons > 1) return null;
      continue;
    }
    nonCloseButtons++;
    // 官方 banner refine：非 close 按钮至多 1 个（:136-140）——popup
    // 允许至多 4 个但 v1 单卡只消费 claim 按钮。
    if (position == 'banner' && nonCloseButtons > 1) return null;
    // 未知动作类型整条丢弃（官方 zod 判别联合只认五类）。
    const knownActions = {
      'open_url',
      'claim_zcode_plan',
      'navigate',
      'copy_text',
    };
    if (!knownActions.contains(type)) return null;
    if (type == 'claim_zcode_plan') {
      final args = action!['args'];
      final planId = args is Map ? '${args['plan_id'] ?? ''}'.trim() : '';
      if (planId.isEmpty || planId.length > 128) return null;
      // 文案与动作绑定同一按钮——claim 按钮自己的 text。
      final trimmed = content.trim();
      buttonText = trimmed.isEmpty ? null : trimmed;
      claimPlanId = planId;
    }
  }

  String? title;
  String? description;
  if (position == 'popup') {
    final t = shape['title'];
    final d = shape['description'];
    if (t is! Map || d is! Map) return null;
    // 官方 zod：content 必须 String——非字符串/非 Map 整条拒收（不是
    // 降级为缺失，审查 M3/④中2）。
    final tContent = t['content'];
    final dContent = d['content'];
    if (tContent is! String || dContent is! String) return null;
    title = _plainText(t);
    description = _plainText(d);
  }
  final visual = position == 'banner' ? shape['background'] : shape['hero'];
  MarketingAsset? image;
  MarketingAsset? darkImage;
  if (visual is Map && visual['type'] == 'image') {
    final img = visual['image'];
    if (img is Map) {
      image = _parseAsset(img['default']);
      darkImage = _parseAsset(img['dark']);
    }
  }
  return MarketingDelivery(
    campaignId: campaignId,
    priority: priority,
    position: position,
    title: title,
    description: description,
    image: image,
    darkImage: darkImage,
    buttonText: buttonText,
    claimPlanId: claimPlanId,
  );
}

/// JSON 整数值宽容归一：int 直取；整值 double（50.0）取整（审查 ——
/// Go/Python 序列化端常见形态，官方 z.number().int() 接受）。
int? _asInt(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num && raw == raw.roundToDouble()) return raw.toInt();
  return null;
}

/// plaintext 文本投影：html/markdown 原文保留（UI 按纯文本渲染），
/// 超长截断（官方上限 20000 字符）。
String? _plainText(Map text) {
  final content = text['content'];
  if (content is! String || content.isEmpty) return null;
  return content.length > 20000 ? content.substring(0, 20000) : content;
}

MarketingAsset? _parseAsset(dynamic raw) {
  if (raw is! Map) return null;
  final srcRaw = raw['src'];
  if (srcRaw is! String || srcRaw.isEmpty || srcRaw.length > 4096) {
    return null;
  }
  final src = Uri.tryParse(srcRaw);
  if (src == null ||
      !(src.scheme == 'https' || src.scheme == 'http') ||
      src.userInfo.isNotEmpty ||
      src.host.isEmpty) {
    return null;
  }
  final sha = '${raw['sha256'] ?? ''}';
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) return null;
  return MarketingAsset(src, sha);
}
