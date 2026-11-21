import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/remote_banner_image.dart';

/// 投放图取回管线（marketing-claim-review-1，审查④高5：此前零直接
/// 测试）。loopback HTTP 全覆盖：哈希对/错、超限、缓存命中、损坏缓存
/// 重下、逐跳 URL 策略（默认 https-only；重定向降级逐跳拦截）、缓存键
/// 净化（路径穿越）、兄弟清理。URL 策略经构造缝注入 loopback 放行
/// （默认策略=生产 https-only 亦有独立断言）。
void main() {
  late Directory dir;
  late HttpServer server;
  final goodBytes = _patternBytes(96);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zp-banner-test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true).catchError((_) => dir);
  });

  /// loopback 放行策略（测试专用）：仅本组服务器端口、且仅 http。
  bool loopback(Uri u) =>
      u.scheme == 'http' && u.host == '127.0.0.1' && u.port == server.port;

  RemoteBannerImage build({bool Function(Uri)? policy}) => RemoteBannerImage(
        baseDir: dir,
        urlPolicy: policy ?? loopback,
      );

  String goodSha() => crypto.sha256.convert(goodBytes).toString();

  void serve(void Function(HttpRequest) handler) {
    server.listen(handler);
  }

  test('默认策略=https-only：http 目标直接拒绝（零请求）', () async {
    var hits = 0;
    serve((req) async {
      hits++;
      await req.response.close();
    });
    final img = RemoteBannerImage(baseDir: dir); // 默认 https-only
    final bytes = await img.fetch(
      cacheKey: 'c',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: goodSha(),
    );
    expect(bytes, isNull);
    expect(hits, 0);
    img.close();
  });

  test('正常路径：下载→sha256 校验→落缓存→二次读缓存零请求', () async {
    var hits = 0;
    serve((req) async {
      hits++;
      req.response.add(goodBytes);
      await req.response.close();
    });
    final img = build();
    final uri = Uri.parse('http://127.0.0.1:${server.port}/a.png');
    final bytes = await img.fetch(
      cacheKey: 'cmp-1',
      src: uri,
      sha256Hex: goodSha(),
    );
    expect(bytes, isNotNull);
    expect(hits, 1);
    final again = await img.fetch(
      cacheKey: 'cmp-1',
      src: uri,
      sha256Hex: goodSha(),
    );
    expect(again, isNotNull);
    expect(hits, 1, reason: '缓存命中不再发请求');
    img.close();
  });

  test('哈希不符返回 null 且不落盘', () async {
    serve((req) async {
      req.response.add(goodBytes);
      await req.response.close();
    });
    final img = build();
    final bytes = await img.fetch(
      cacheKey: 'cmp-bad',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: 'f' * 64,
    );
    expect(bytes, isNull);
    expect(await dir.list().isEmpty, isTrue, reason: '不符不落任何文件');
    img.close();
  });

  test('缓存损坏（哈希不符的旧文件）删除后重下', () async {
    final digest = crypto.sha256.convert(utf8.encode('cmp-dirty')).toString();
    final stale = File(
      '${dir.path}${Platform.pathSeparator}zp-banner-$digest.img',
    );
    await stale.writeAsBytes(Uint8List.fromList([1, 2, 3]));
    var hits = 0;
    serve((req) async {
      hits++;
      req.response.add(goodBytes);
      await req.response.close();
    });
    final img = build();
    final bytes = await img.fetch(
      cacheKey: 'cmp-dirty',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: goodSha(),
    );
    expect(bytes, isNotNull, reason: '坏缓存被清后重下成功');
    expect(hits, 1);
    img.close();
  });

  test('重定向逐跳过闸：首跳放行、目标端口不在策略内=拒绝（降级拦截）',
      () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    other.listen((req) async {
      req.response.add(goodBytes);
      await req.response.close();
    });
    serve((req) async {
      req.response.statusCode = 302;
      req.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${other.port}/down.png', // 端口不在 loopback 策略
      );
      await req.response.close();
    });
    final img = build(); // 策略只放行 server.port
    final bytes = await img.fetch(
      cacheKey: 'cmp-redir',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: goodSha(),
    );
    expect(bytes, isNull, reason: '重定向目标逐跳过闸——策略外端口拒绝');
    img.close();
  });

  test('策略内重定向（同端口路径跳）跟随成功', () async {
    var first = true;
    serve((req) async {
      if (first) {
        first = false;
        req.response.statusCode = 302;
        req.response.headers.set(
          HttpHeaders.locationHeader,
          '/real.png', // 相对解析→同主机同端口=策略内
        );
        await req.response.close();
        return;
      }
      req.response.add(goodBytes);
      await req.response.close();
    });
    final img = build();
    final bytes = await img.fetch(
      cacheKey: 'cmp-hop',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: goodSha(),
    );
    expect(bytes, isNotNull, reason: '策略内跳转正常跟随');
    img.close();
  });

  test('超 2MiB 拒绝（流式截断不整读）', () async {
    serve((req) async {
      req.response.add(Uint8List(3 * 1024 * 1024));
      await req.response.close();
    });
    final img = build();
    final bytes = await img.fetch(
      cacheKey: 'cmp-big',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: goodSha(),
    );
    expect(bytes, isNull);
    img.close();
  });

  test('缓存键净化：campaign_id 路径穿越/分隔符不越出缓存目录', () async {
    serve((req) async {
      req.response.add(goodBytes);
      await req.response.close();
    });
    final img = build();
    final bytes = await img.fetch(
      cacheKey: '../../evil/../../../../x',
      src: Uri.parse('http://127.0.0.1:${server.port}/a.png'),
      sha256Hex: goodSha(),
    );
    expect(bytes, isNotNull, reason: '合法下载照常');
    final entries = await dir.list().toList();
    expect(entries, hasLength(1));
    expect(entries.single is File, isTrue);
    expect(entries.single.path.contains('evil'), isFalse);
    img.close();
  });

  test('兄弟清理：新 campaign 写入后旧缓存被清（单卡不堆积）', () async {
    serve((req) async {
      req.response.add(goodBytes);
      await req.response.close();
    });
    final img = build();
    final uri = Uri.parse('http://127.0.0.1:${server.port}/a.png');
    await img.fetch(cacheKey: 'cmp-old', src: uri, sha256Hex: goodSha());
    expect(await dir.list().length, 1);
    await img.fetch(cacheKey: 'cmp-new', src: uri, sha256Hex: goodSha());
    expect(await dir.list().length, 1, reason: '旧 campaign 缓存被清');
    img.close();
  });
}

/// 确定性字节图案（管线只做字节级 sha256 校验，PNG 解码归 widget 层）。
Uint8List _patternBytes(int n) =>
    Uint8List.fromList(List.generate(n * 4, (i) => i % 251));
