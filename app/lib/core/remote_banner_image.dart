import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// 官方营销投放图取回（marketing-claim-1；对抗审查修复批
/// marketing-claim-review-1 安全加固）。
///
/// 官方投放图资产自带 sha256（marketingAssetSchema：src+sha256），
/// 桌面端下载后按哈希校验——本工具同款：取字节→校验→落缓存→返回。
/// 任何失败一律返回 null：领取卡是增益面，退纯文字态即可，绝不抛错。
///
/// 安全边界（审查③高-2/中-1/中-2/中-3）：
/// - **重定向逐跳校验**：不自动跟随（Dart 会跟随 https→http 降级），
///   手动循环 ≤3 跳且每一跳必须仍为 https，否则放弃；
/// - **缓存键净化**：服务端 campaign_id 是无字符集约束的任意串——
///   文件名一律用 `sha256(cacheKey)`，杜绝路径穿越/非法字符/超长；
/// - 单卡场景缓存即写即清：成功写入后清除同前缀旧文件（campaign 轮换
///   不堆积）；`.part` 半写残留同步清理；
/// - body 收集整体限时+Content-Length 预判，慢滴灌对端不再能挂住 Future。
class RemoteBannerImage {
  /// 单图字节上限（压缩字节）：官方 banner 资产为数百 KB 级位图。
  static const maxBytes = 2 * 1024 * 1024;

  /// 手动重定向上限。
  static const maxRedirects = 3;

  /// 缓存文件名前缀（键为其后 sha256 十六进制）。
  static const _filePrefix = 'zp-banner-';
  static const _fileSuffix = '.img';

  final Duration timeout;

  /// 缓存根目录（默认系统临时目录；测试注入临时目录）。
  final Future<io.Directory> Function() baseDirProvider;

  /// 逐跳 URL 策略（默认仅 https）。测试可注入 loopback 放行策略——
  /// 策略按**每一跳**独立评估（重定向后仍须过闸，https→http 降级在
  /// 任何策略下都不会因首跳 https 而被放行）。
  final bool Function(Uri uri) urlPolicy;

  io.HttpClient? _httpClient;
  io.HttpClient get _client =>
      _httpClient ??= (io.HttpClient()..connectionTimeout = timeout);

  static bool _httpsOnly(Uri uri) => uri.scheme == 'https';

  RemoteBannerImage({
    this.timeout = const Duration(seconds: 15),
    io.Directory? baseDir,
    bool Function(Uri uri)? urlPolicy,
  })  : baseDirProvider = baseDir == null ? _systemTemp : (() async => baseDir),
        urlPolicy = urlPolicy ?? _httpsOnly;

  static Future<io.Directory> _systemTemp() async => io.Directory.systemTemp;

  void close() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  /// 取回投放图；cacheKey 为任意服务端串（内部已净化）。
  Future<Uint8List?> fetch({
    required String cacheKey,
    required Uri src,
    required String sha256Hex,
  }) async {
    try {
      final dir = await baseDirProvider();
      final file = io.File('${dir.path}${io.Platform.pathSeparator}'
          '$_filePrefix${_sanitize(cacheKey)}$_fileSuffix');
      if (await file.exists()) {
        final cached = await file.readAsBytes();
        if (_matches(cached, sha256Hex)) return cached;
        // 缓存与哈希不符（半写/换图）——删除后重下。
        await file.delete().catchError((_) => file);
      }
      final bytes = await _download(src);
      if (bytes == null || !_matches(bytes, sha256Hex)) return null;
      // 先写临时名再改名：半写文件不会以正式键面世。
      final tmp = io.File('${file.path}.part');
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        await tmp.delete().catchError((_) => tmp);
        return null;
      }
      await _cleanupSiblings(file);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 键净化：sha256 十六进制——任意 campaign_id（含 `/`、`..`、控制
  /// 字符、超长、大小写碰撞）映射为安全定长文件名。
  static String _sanitize(String key) =>
      crypto.sha256.convert(utf8.encode(key)).toString();

  /// 单卡场景：写入成功后清除其它同前缀缓存（campaign 轮换不堆积）。
  Future<void> _cleanupSiblings(io.File current) async {
    try {
      final dir = current.parent;
      await for (final entry in dir.list()) {
        if (entry is! io.File) continue;
        final name = entry.uri.pathSegments.last;
        if (entry.path == current.path) continue;
        if (name.startsWith(_filePrefix) &&
            (name.endsWith(_fileSuffix) || name.endsWith('$_fileSuffix.part'))) {
          await entry.delete().catchError((_) => entry);
        }
      }
    } catch (_) {
      // 清理失败不影响取图结果。
    }
  }

  /// 下载并整体限时；重定向手动逐跳过 URL 策略闸（默认仅 https——
  /// Dart 自动跟随会把 https→http 降级放行，故不自动跟随）。
  Future<Uint8List?> _download(Uri src) async {
    var target = src;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (!urlPolicy(target)) return null;
      final io.HttpClientRequest? req;
      try {
        req = await _client.getUrl(target);
      } catch (_) {
        return null;
      }
      req.followRedirects = false;
      final io.HttpClientResponse res;
      try {
        res = await req.close().timeout(timeout);
      } on TimeoutException {
        req.abort();
        return null;
      } catch (_) {
        return null;
      }
      final location = res.headers.value(io.HttpHeaders.locationHeader);
      final isRedirect = res.statusCode >= 300 && res.statusCode < 400;
      if (isRedirect) {
        // 每跳必须 https——Dart 自动跟随会把 https→http 降级放行。
        final next = location == null
            ? null
            : target.resolve(location);
        unawaited(res.drain<void>().catchError((_) {}));
        if (next == null || hop == maxRedirects) return null;
        target = next;
        continue;
      }
      if (res.statusCode != 200) {
        unawaited(res.drain<void>().catchError((_) {}));
        return null;
      }
      final declared = res.contentLength;
      if (declared > 0 && declared > maxBytes) {
        unawaited(res.drain<void>().catchError((_) {}));
        return null;
      }
      final builder = BytesBuilder(copy: false);
      try {
        await (() async {
          await for (final chunk in res) {
            builder.add(chunk);
            if (builder.length > maxBytes) return;
          }
        })().timeout(timeout);
      } on TimeoutException {
        req.abort();
        return null;
      } catch (_) {
        return null;
      }
      if (builder.isEmpty || builder.length > maxBytes) return null;
      return builder.takeBytes();
    }
    return null;
  }

  bool _matches(Uint8List bytes, String sha256Hex) =>
      crypto.sha256.convert(bytes).toString() == sha256Hex.toLowerCase();
}
