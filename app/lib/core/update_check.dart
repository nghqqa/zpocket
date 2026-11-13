// 应用内更新——检查与元数据。
//
// 数据源：GitHub `releases/latest`（一次返回 tag+各 APK 资产 URL+官方
// sha256 digest——v1.0.4 实测 digest 与 SHA256SUMS 逐字节吻合，作为
// 下载校验的信任锚）。直连 api.github.com；失败静默（检查是增强不是
// 关键路径）。不引 http/dio：dart:io HttpClient 走 voice_refine.dart
// 的超时分层先例。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const _kRepo = 'JZYLukis/zcode-pocket';

/// ZPocket 自建更新清单（P0 文件下载批同期，2026-11-13）：HTTPS 静态
/// JSON 放自有服务器/域名，格式
/// `{"version":"1.0.6","notes":"…","assets":[{"name":"zpocket-1.0.6-
/// arm64-v8a.apk","url":"https://…/zpocket-1.0.6-arm64-v8a.apk",
/// "sha256":"64 位十六进制"}]}`——assets.name 须含 ABI 串（assetForAbi 按
/// name 匹配）。置空串=回落 GitHub Releases（_kRepo，上游仓库——签名
/// 不同装不上，仅作保留路径）。发版用 tools/release.py 一键产出清单。
const kUpdateManifestUrl =
    'https://nghqqa.cn/updates/manifest.json';

/// 应用内更新已恢复（kInAppUpdateDisabled=false）：更新源=上面的自建
/// 清单，签名校验锚=本 fork 自有发布钥（MainActivity.RELEASE_CERT_SHA256）。
/// 更新源偏好取值（ui.updateSource）：auto=双通道测速择优 /
/// selfhost=自有服务器（nghqqa.cn，国内快）/ github=GitHub Releases
/// （海外快）。三处发布同一构建，仅下载路径不同。
const kUpdateSourceAuto = 'auto';
const kUpdateSourceSelfHost = 'selfhost';
const kUpdateSourceGitHub = 'github';
const _kGitHubReleaseApi = 'https://api.github.com/repos/$_kRepo/releases/latest';

/// 延迟探测签名：返回该 URL 的 RTT 毫秒，null=不可达。
typedef UpdateLatencyProbe = Future<int?> Function(String url);

/// 默认探测：GET 首包+关闭计时，2 秒超时=不可达。
Future<int?> defaultUpdateLatencyProbe(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  final sw = Stopwatch()..start();
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 2));
    final res = await req.close().timeout(const Duration(seconds: 2));
    await res.drain<void>().timeout(const Duration(seconds: 2));
    return sw.elapsedMilliseconds;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 依据偏好解析更新源。'auto' 并行探测两通道 RTT，快者胜；单边不可达
/// 自动落另一边；双不可达回落自建（国内主用户常态）。probe 可注入测试。
Future<String> resolveUpdateSource(
  String pref, {
  UpdateLatencyProbe? probe,
}) async {
  if (pref == kUpdateSourceSelfHost) return kUpdateManifestUrl;
  if (pref == kUpdateSourceGitHub) return 'github';
  final p = probe ?? defaultUpdateLatencyProbe;
  final r = await Future.wait([
    p(kUpdateManifestUrl),
    p(_kGitHubReleaseApi),
  ]);
  final selfhostMs = r[0];
  final githubMs = r[1];
  if (selfhostMs == null && githubMs == null) return kUpdateManifestUrl;
  if (selfhostMs == null) return 'github';
  if (githubMs == null) return kUpdateManifestUrl;
  // 平手回落自建（国内主用户常态）。
  return selfhostMs <= githubMs ? kUpdateManifestUrl : 'github';
}

const kInAppUpdateDisabled = false;

/// 测试缝：清单 URL 覆盖（同 debugUpdateApiBaseOverride 先例）。
@visibleForTesting
String? debugManifestUrlOverride;

/// 测试缝：更新源覆盖（绕过测速，直接指定 selfhost/github/绝对清单 URL）。
@visibleForTesting
String? debugUpdateSourceOverride;

/// 测试缝：本机 HttpServer 覆盖 API 基址（relay_v2_test 同款先例）。
@visibleForTesting
String? debugUpdateApiBaseOverride;

class UpdateAsset {
  final String name;
  final String url;
  final String sha256Hex; // 官方 digest（去 sha256: 前缀）
  const UpdateAsset(this.name, this.url, this.sha256Hex);
}

class UpdateInfo {
  final String version; // '1.0.5'（去 v 前缀）
  final String notes; // 朴素文本 changelog
  final List<UpdateAsset> assets;
  const UpdateInfo(this.version, this.notes, this.assets);

  UpdateAsset? assetForAbi(String abi) => pickAssetForAbi(assets, abi);
}

/// 版本比较：versionName 形如 `1.0.4-<12位SHA>`（build-release 出包），
/// 取 `-` 前 SemVer 与 tag（v 前缀可选）比较。返回 true=远端更新。
bool isNewerVersion(String remoteTag, String currentVersionName) {
  final remote = semverOf(remoteTag);
  final current = semverOf(currentVersionName);
  if (remote == null || current == null) return false;
  final cmp = compareSemver(remote, current);
  return cmp > 0;
}

/// `v1.0.5` / `1.0.5-abc123` → [1,0,5]；不合法返回 null。
List<int>? semverOf(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final dash = s.indexOf('-');
  if (dash >= 0) s = s.substring(0, dash);
  final parts = s.split('.');
  if (parts.length != 3) return null;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    nums.add(n);
  }
  return nums;
}

int compareSemver(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return 0;
}

/// ABI → 资产匹配（资产名后缀 zcode-pocket-<版本>-<abi>.apk）。
UpdateAsset? pickAssetForAbi(List<UpdateAsset> assets, String abi) {
  // SUPPORTED_ABIS[0] 可能返回 arm64-v8a/armeabi-v7a/x86_64 等；做一次
  // 常见别名归一（arm64→arm64-v8a）。
  final normalized = switch (abi) {
    'arm64' => 'arm64-v8a',
    'arm32' || 'armeabi' => 'armeabi-v7a',
    'x86' || 'x64' => 'x86_64',
    _ => abi,
  };
  for (final a in assets) {
    if (a.name.endsWith('-$normalized.apk')) return a;
  }
  return null;
}

/// `sha256:abcd…` → `abcd…`；无前缀且形如 64 位十六进制也接受。
String? parseDigest(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.startsWith('sha256:')) s = s.substring(7);
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(s) ? s : null;
}

/// Release body（markdown）→ 朴素文本：去标题井号/链接语法/表格竖线，
/// 折叠连续空行。仅用于弹窗展示，不做完整 md 渲染。
String stripMarkdownNotes(String body) {
  final out = StringBuffer();
  var blankRun = false;
  for (final rawLine in const LineSplitter().convert(body)) {
    var line = rawLine
        .replaceAll(RegExp(r'^#{1,6}\s*'), '')
        .replaceAllMapped(
            RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll(RegExp(r'^\|.*\|$'), '')
        .replaceAll(RegExp(r'^[-*]\s+'), '· ')
        .replaceAll('> ', '')
        .trimRight();
    if (line.trim().isEmpty) {
      if (!blankRun && out.isNotEmpty) out.writeln();
      blankRun = true;
      continue;
    }
    blankRun = false;
    out.writeln(line);
  }
  return out.toString().trim();
}

class UpdateCheckException implements Exception {
  final String reason;
  const UpdateCheckException(this.reason);
  @override
  String toString() => 'UpdateCheckException($reason)';
}

/// 拉取 latest release 元数据。抛 [UpdateCheckException]（调用方静默/
/// 提示自定）。updateSource：auto=测速择优（双通道内容一致）；
/// selfhost=自建清单；github=GitHub Releases。
Future<UpdateInfo> fetchLatestRelease({
  String updateSource = kUpdateSourceAuto,
  UpdateLatencyProbe? probe,
}) async {
  final resolved = await resolveUpdateSource(
    debugUpdateSourceOverride ?? updateSource,
    probe: probe,
  );
  if (resolved == 'github') {
    return _fetchGitHubLatest();
  }
  final manifestUrl = debugManifestUrlOverride ?? kUpdateManifestUrl;
  return _fetchManifest(manifestUrl);
}

/// GitHub Releases 通道（海外快；资产 digest 由 GitHub 官方提供）。
Future<UpdateInfo> _fetchGitHubLatest() async {
  final base = debugUpdateApiBaseOverride ?? 'https://api.github.com';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .getUrl(Uri.parse('$base/repos/$_kRepo/releases/latest'))
        .timeout(const Duration(seconds: 10));
    // 未认证 GitHub API 要求 User-Agent。
    req.headers.set('User-Agent', 'zpocket-updater');
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 12));
    if (res.statusCode == 403 || res.statusCode == 429) {
      throw const UpdateCheckException('rate-limited');
    }
    if (res.statusCode != 200) {
      throw UpdateCheckException('http-${res.statusCode}');
    }
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    return parseReleaseJson(body);
  } on UpdateCheckException {
    rethrow;
  } on Object {
    throw const UpdateCheckException('network');
  } finally {
    client.close(force: true);
  }
}

/// 自建清单拉取（kUpdateManifestUrl）。同一超时分层。
Future<UpdateInfo> _fetchManifest(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    req.headers.set('Accept', 'application/json');
    final res = await req.close().timeout(const Duration(seconds: 12));
    if (res.statusCode == 403 || res.statusCode == 429) {
      throw const UpdateCheckException('rate-limited');
    }
    if (res.statusCode != 200) {
      throw UpdateCheckException('http-${res.statusCode}');
    }
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    return parseManifestJson(body);
  } on UpdateCheckException {
    rethrow;
  } on Object {
    throw const UpdateCheckException('network');
  } finally {
    client.close(force: true);
  }
}

/// 自建清单 JSON 解析（纯函数，可测）。缺 version/assets 视为坏清单；
/// assets 单条缺 name/url/sha256 剔除该条（全部无效则空 assets=无更新可用）。
UpdateInfo parseManifestJson(String body) {
  final Map<dynamic, dynamic> json;
  try {
    json = jsonDecode(body) as Map<dynamic, dynamic>;
  } on Object {
    throw const UpdateCheckException('bad-json');
  }
  final version = json['version'];
  if (version is! String || version.isEmpty) {
    throw const UpdateCheckException('no-version');
  }
  final assetsRaw = json['assets'];
  final assets = <UpdateAsset>[];
  if (assetsRaw is List) {
    for (final a in assetsRaw) {
      if (a is! Map) continue;
      final name = a['name'];
      final url = a['url'];
      final sha = a['sha256'];
      if (name is! String || url is! String || sha is! String) continue;
      if (sha.isEmpty) continue;
      assets.add(UpdateAsset(name, url, sha.toLowerCase()));
    }
  }
  final notes = json['notes'];
  return UpdateInfo(
    version,
    notes is String ? notes : '',
    assets,
  );
}

/// JSON 解析（纯函数，可测）。
UpdateInfo parseReleaseJson(String body) {
  final Map<dynamic, dynamic> json;
  try {
    json = jsonDecode(body) as Map<dynamic, dynamic>;
  } on Object {
    throw const UpdateCheckException('bad-json');
  }
  final tagName = json['tag_name'];
  if (tagName is! String) throw const UpdateCheckException('no-tag');
  final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
  final assetsRaw = json['assets'];
  final assets = <UpdateAsset>[];
  if (assetsRaw is List) {
    for (final a in assetsRaw) {
      if (a is! Map) continue;
      final name = a['name'];
      final url = a['browser_download_url'];
      if (name is! String || url is! String) continue;
      final digest = parseDigest(a['digest'] as String?);
      if (digest == null) continue; // 无官方哈希的资产不参与应用内更新
      assets.add(UpdateAsset(name, url, digest));
    }
  }
  final notesBody = json['body'];
  return UpdateInfo(
    version,
    stripMarkdownNotes(notesBody is String ? notesBody : ''),
    assets,
  );
}
