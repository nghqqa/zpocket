import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/state/marketing_controller.dart';

/// 福利提醒卡状态机（marketing-claim-1；marketing-reminder-1 起
/// touch/reminder-only）：经 originProvider 指向 loopback 走真实 HTTP。
/// 覆盖：每账号闸、失败退避（审查②）、账号缓存与 onAccountChanged
/// 钩子（②）、跨账号陈旧卡守卫（①/②M2）、fire-and-forget 上报
/// （④高3）、空快照清卡（④中4）、provider 抛错不卡死（②）。
void main() {
  late String accountId;
  var touchHits = 0;

  MarketingController build(Uri origin, {DateTime Function()? clock}) =>
      MarketingController(
        accountIdProvider: () async => accountId,
        jwtProvider: (id) async => 'jwt-$id',
        deviceMidProvider: () async => '0f0b9ee9-3b1c-4a4e-9d2f-6d7c8f9a0b1c',
        localeProvider: () => 'zh-CN',
        appVersionProvider: () async => '1.0.7-test',
        platformProvider: () => 'android',
        originProvider: () => origin,
        clock: clock ?? DateTime.now,
      );

  setUp(() {
    accountId = 'acc-1';
    touchHits = 0;
  });

  test('首拉出卡（banner 优先）+同账号闸+force 绕过', () async {
    final origin = await _Server.start(
      onTouch: () {
        touchHits++;
        return _touchResponse([
          _popupDelivery('pop-1'),
          _bannerDelivery('cmp-banner'),
        ]);
      },
    );
    final c = build(origin);
    await c.pull();
    expect(c.card, isNotNull);
    expect(
      c.card!.delivery.campaignId,
      'cmp-banner',
      reason: 'banner 优先于 popup',
    );
    expect(touchHits, 1);
    // 同账号非 force：每账号闸，不再发请求。
    await c.pull();
    expect(touchHits, 1);
    // force（下拉/顶栏刷新）：绕过闸再拉。
    await c.pull(force: true);
    expect(touchHits, 2);
  });

  test('失败退避：失败后通知触发不再发请求；force 绕过；成功重置（审查②H1）', () async {
    var fail = true;
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final origin = await _Server.start(
      onTouch: () {
        touchHits++;
        return fail
            ? {'code': 403}
            : _touchResponse([_bannerDelivery('cmp-b')]);
      },
    );
    final c = build(origin, clock: () => now);
    await c.pull();
    expect(touchHits, 1, reason: '首次尝试已发出');
    expect(c.card, isNull);
    // 时间前进 10s（< 30s 退避）：再触发不发。
    now = now.add(const Duration(seconds: 10));
    await c.ensurePulled();
    expect(touchHits, 1, reason: '退避期内零请求——击穿即按通知频率轮询');
    // 退避窗口过后：恢复尝试。
    now = now.add(const Duration(seconds: 25));
    await c.ensurePulled();
    expect(touchHits, 2, reason: '30s 退避到期后允许重试');
    // 仍失败→退避翻倍（60s）：期内零请求。
    now = now.add(const Duration(seconds: 50));
    await c.ensurePulled();
    expect(touchHits, 2);
    // 成功后退避重置为 30s。
    fail = false;
    now = now.add(const Duration(seconds: 15));
    await c.ensurePulled();
    expect(touchHits, 3);
    expect(c.card?.delivery.campaignId, 'cmp-b');
    now = now.add(const Duration(seconds: 35));
    await c.ensurePulled();
    expect(touchHits, 3, reason: '每账号闸接管（成功后不再自动拉）');
  });

  test('账号缓存+onAccountChanged：切号后缓存失效立即按新账号重拉（②M7）', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-a1')]),
    );
    final c = build(origin);
    await c.pull();
    expect(c.card!.accountId, 'acc-1');
    accountId = 'acc-2';
    // 60s 账号节流内：ensurePulled 用缓存账号=零新请求（闸也命中）。
    await c.ensurePulled();
    expect(c.card!.accountId, 'acc-1');
    // 生产接线=AccountStore.onChanged → onAccountChanged：失效缓存。
    c.onAccountChanged();
    await c.ensurePulled();
    expect(c.card!.accountId, 'acc-2');
  });

  test('跨账号陈旧卡：切号后拉取失败也不保留旧账号卡（①H3/②M2）', () async {
    var failForB = false;
    final origin = await _Server.start(
      onTouch: () =>
          failForB ? {'code': 500} : _touchResponse([_bannerDelivery('cmp-a')]),
    );
    final c = build(origin);
    await c.pull();
    expect(c.card, isNotNull);
    accountId = 'acc-2';
    failForB = true;
    c.onAccountChanged();
    await c.ensurePulled();
    expect(c.card, isNull, reason: 'B 会话不得展示 A 的投放');
  });

  test('拉取失败静默保旧卡+10min 无成功收卡（②L2）', () async {
    var failTouch = false;
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final origin = await _Server.start(
      onTouch: () => failTouch
          ? {'code': 403}
          : _touchResponse([_bannerDelivery('cmp-keep')]),
    );
    final c = build(origin, clock: () => now);
    await c.pull();
    expect(c.card?.delivery.campaignId, 'cmp-keep');
    failTouch = true;
    now = now.add(const Duration(minutes: 11));
    await c.pull(force: true);
    expect(c.card, isNull, reason: '10min 无成功按官方语义收卡');
  });

  test('成功空快照清卡（审查④中4）', () async {
    final origin = await _Server.start(onTouch: () => _touchResponse([]));
    final c = build(origin);
    // 预置一张卡（模拟上一轮拉取结果）。
    await c.pull(force: true);
    expect(c.card, isNull, reason: '空 deliveries=无投放，零占位');
  });

  test('无账号：清卡静默（未登录态）', () async {
    var touched = false;
    final origin = await _Server.start(
      onTouch: () {
        touched = true;
        return _touchResponse([]);
      },
    );
    accountId = '';
    final c = build(origin);
    await c.pull();
    expect(touched, isFalse);
    expect(c.card, isNull);
  });

  // ---------------- collapse-1：收起/展开（用户拍板「晚点领」）。

  test('收起：仅视图态——同投放 force 重拉保持收起，展开复原，不上报', () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-c')]),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    expect(c.isCollapsed, isFalse);
    c.collapse(c.card!);
    expect(c.isCollapsed, isTrue);
    // 同投放 force 重拉：保持收起（不重复打扰）。
    await c.pull(force: true);
    expect(c.card, isNotNull);
    expect(c.isCollapsed, isTrue);
    c.expand();
    expect(c.isCollapsed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(actions, isEmpty, reason: '收起/展开是纯视图态，不消耗上报配额');
  });

  test('收起键控：换投放自动回展开；claiming 中禁收起', () async {
    var campaign = 'cmp-a';
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery(campaign)]),
    );
    final c = build(origin);
    await c.pull();
    c.collapse(c.card!);
    expect(c.isCollapsed, isTrue);
    // 换投放（服务端轮换）：新 campaign 默认展开。
    campaign = 'cmp-b';
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-b');
    expect(c.isCollapsed, isFalse, reason: '收起只对当初那张投放生效');
    // claiming 中：collapse 无效（与 UI 禁用同口径）。
    c.claiming = true;
    c.collapse(c.card!);
    expect(c.isCollapsed, isFalse);
    c.claiming = false;
  });

  test('dismiss 撤销：恢复卡片+解除抑制；不补发 confirm（审查①M2）', () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-undo')]),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    final dismissed = c.card!;
    await c.dismiss(dismissed);
    expect(c.card, isNull);
    await _until(() => actions.isNotEmpty);
    expect(actions.last['action_type'], 'cancel');
    c.undoDismiss();
    expect(c.card, isNotNull, reason: '撤销恢复卡片');
    expect(c.card!.delivery.campaignId, 'cmp-undo');
    // 抑制已解除：force 重拉同 campaign 仍出卡。
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-undo');
    expect(
      actions.where((a) => a['action_type'] == 'confirm'),
      isEmpty,
      reason: '撤销不补发 confirm（分析数据容忍单向误差，决策记录 留痕）',
    );
  });

  test('campaign 级收起语义：A→B→A 回到 A 时保持收起（审查②L1 钉语义）', () async {
    var campaign = 'cmp-a';
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery(campaign)]),
    );
    final c = build(origin);
    await c.pull();
    c.collapse(c.card!);
    expect(c.isCollapsed, isTrue);
    campaign = 'cmp-b';
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-b');
    expect(c.isCollapsed, isFalse, reason: '换投放展开');
    campaign = 'cmp-a';
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-a');
    expect(c.isCollapsed, isTrue, reason: 'campaign 级延期：同一活动不因中间换投放而反复打扰');
  });

  test('用户关闭：cancel 上报最终到达+本账号本会话 suppress', () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-dismiss')]),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    await c.dismiss(c.card!);
    expect(c.card, isNull);
    await _until(() => actions.isNotEmpty);
    expect(actions, [
      {'campaign_id': 'cmp-dismiss', 'action_type': 'cancel'},
    ]);
    await c.pull(force: true);
    expect(c.card, isNull);
  });

  test('provider 抛错不卡死：pulling 复位（②M4）', () async {
    // deviceMidProvider 抛错（华为 Keystore 损坏形态）——拉取不抛出、
    // 不留 pulling 卡死。
    final broken = MarketingController(
      accountIdProvider: () async => accountId,
      jwtProvider: (id) async => 'jwt-$id',
      deviceMidProvider: () async => throw const SocketException('keystore'),
      localeProvider: () => 'zh-CN',
      appVersionProvider: () async => '0',
      platformProvider: () => 'android',
      originProvider: () => Uri.parse('https://zcode.z.ai'),
    );
    await broken.pull();
    expect(broken.pulling, isFalse, reason: 'finally 复位，不卡 pulling');
    expect(broken.card, isNull);
  });
}

Future<void> _until(bool Function() test) async {
  for (var i = 0; i < 100 && !test(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(test(), isTrue, reason: '轮询超时（fire-and-forget 未到达）');
}

// ------------------------------------------------------------- 服务假件

class _Server {
  static Future<Uri> start({
    required Map<String, dynamic> Function() onTouch,
    void Function(Map<String, dynamic>)? onAction,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      final body = text.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(text) as Map).cast<String, dynamic>();
      Map<String, dynamic>? payload;
      if (req.uri.path == '/api/v1/marketing/touch') {
        payload = onTouch();
      } else if (req.uri.path == '/api/v1/marketing/touch/action') {
        onAction?.call(body);
        payload = {'code': 0};
      }
      final status = payload?.remove('__status__') as int? ?? 200;
      // null=断连不回包（传输异常注入）。
      if (payload == null) {
        final socket = await req.response.detachSocket();
        socket.destroy();
        return;
      }
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(payload));
      await req.response.close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}');
  }
}

Map<String, dynamic> _touchResponse(List<Map<String, dynamic>> deliveries) => {
  'code': 0,
  'data': {
    'server_time': 1760000000,
    'language': 'zh-CN',
    'deliveries': deliveries,
  },
};

Map<String, dynamic> _bannerDelivery(String campaignId) => {
  'campaign_id': campaignId,
  'priority': 80,
  'resource_position': 'banner',
  'banner': {
    'background': {
      'type': 'image',
      'image': {
        'default': {
          'src': 'https://static.zcode.z.ai/$campaignId.png',
          'sha256': 'a' * 64,
        },
      },
    },
    'buttons': [
      {
        'text': {'format': 'plaintext', 'content': '领取'},
        'action': {
          'type': 'claim_zcode_plan',
          'args': {'plan_id': 'plan-$campaignId'},
        },
      },
    ],
  },
};

Map<String, dynamic> _popupDelivery(String campaignId) => {
  'campaign_id': campaignId,
  'priority': 50,
  'resource_position': 'popup',
  'popup': {
    'title': {'format': 'plaintext', 'content': '限时福利'},
    'description': {'format': 'plaintext', 'content': '今日有效'},
    'buttons': [
      {
        'text': {'format': 'plaintext', 'content': '领取'},
        'action': {
          'type': 'claim_zcode_plan',
          'args': {'plan_id': 'plan-$campaignId'},
        },
      },
    ],
  },
};
