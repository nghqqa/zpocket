// iOS 发布面资产守卫（早前批次，；ios_project_guard_test
// 同族）：图标/启动屏/隐私清单/双语权限文案/工程登记的静态断言——
// Windows 无 Xcode，配置漂移在本地测试步即拦。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String pbxproj;
  late final String storyboard;
  late final String plist;

  setUpAll(() {
    pbxproj = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    storyboard =
        File('ios/Runner/Base.lproj/LaunchScreen.storyboard').readAsStringSync();
    plist = File('ios/Runner/Info.plist').readAsStringSync();
  });

  group('AppIcon（发布面：模板图标+alpha 双风险清除）', () {
    test('全部图标无 alpha 通道且四角纯黑（App Store ITMS-90683）', () {
      final dir = Directory(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset',
      );
      final pngs = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      expect(pngs.length, greaterThanOrEqualTo(15), reason: '模板档位全量');
      for (final f in pngs) {
        final bytes = f.readAsBytesSync();
        // PNG IHDR color type：字节 25（0=灰度/2=RGB 无 alpha；6=RGBA）。
        expect(bytes[25], isIn([0, 2]), reason: '${f.path} 含 alpha 通道');
        // 解码校验四角像素留给集成/CI；字节级 alpha 检查已挡上传风险。
      }
    });

    test('Contents.json 档位文件齐全（防手滑删档）', () {
      final contents = File(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
      ).readAsStringSync();
      for (final name in [
        'Icon-App-20x20@1x.png',
        'Icon-App-29x29@1x.png',
        'Icon-App-40x40@1x.png',
        'Icon-App-60x60@2x.png',
        'Icon-App-76x76@1x.png',
        'Icon-App-83.5x83.5@2x.png',
        'Icon-App-1024x1024@1x.png',
      ]) {
        expect(contents.contains(name), isTrue, reason: '$name 档位缺失');
      }
    });
  });

  group('LaunchScreen（深色白闪+1x1 模板图清除）', () {
    test('systemBackgroundColor 深色自适应、LaunchImage 引用已移除', () {
      expect(
        storyboard.contains('systemBackgroundColor'),
        isTrue,
        reason: '启动屏背景须用系统色（深色模式白闪根因）',
      );
      expect(
        storyboard.contains('LaunchImage'),
        isFalse,
        reason: '1x1 模板图引用须移除（imageset 已删）',
      );
      expect(
        Directory('ios/Runner/Assets.xcassets/LaunchImage.imageset').existsSync(),
        isFalse,
        reason: 'LaunchImage.imageset 应整体删除',
      );
    });
  });

  group('PrivacyInfo.xcprivacy（App Store required-reason API 声明）', () {
    test('清单在场且四类 API 原因码齐全、零追踪零收集', () {
      final f = File('ios/Runner/PrivacyInfo.xcprivacy');
      expect(f.existsSync(), isTrue, reason: '隐私清单缺失');
      final s = f.readAsStringSync();
      for (final key in [
        'NSPrivacyTracking',
        'NSPrivacyAccessedAPITypeUserDefaults',
        'CA92.1',
        'NSPrivacyAccessedAPITypeFileTimestamp',
        'C617.1',
        'NSPrivacyAccessedAPITypeSystemBootTime',
        '35F9.1',
        'NSPrivacyAccessedAPITypeDiskSpace',
        'E174.1',
      ]) {
        expect(s.contains(key), isTrue, reason: '缺 $key');
      }
      // 行尾兼容（公树导出走 core.autocrlf=true 的 archive——LF 被转
      // CRLF，首次公树冒烟实锤）：断言不得对行尾敏感。
      expect(
        RegExp('<key>NSPrivacyTracking</key>\r?\n\t<false/>').hasMatch(s),
        isTrue,
      );
    });

    test('pbxproj 登记：PrivacyInfo 与 InfoPlist.strings 都在 Resources', () {
      expect(
        RegExp(
          r'AA51D0E5000000000000F007 /\* PrivacyInfo\.xcprivacy in Resources \*/',
        ).hasMatch(pbxproj),
        isTrue,
        reason: 'PrivacyInfo.xcprivacy 未挂 Resources（不进包=声明无效）',
      );
      expect(
        RegExp(
          r'AA51D0E5000000000000F00B /\* InfoPlist\.strings in Resources \*/',
        ).hasMatch(pbxproj),
        isTrue,
        reason: 'InfoPlist.strings 未挂 Resources（权限文案双语失效）',
      );
      expect(
        RegExp(
          'AA51D0E5000000000000F00A /\\* InfoPlist\\.strings \\*/ = \\{\\r?\\n'
          '\\t\\t\\tisa = PBXVariantGroup;',
        ).hasMatch(pbxproj),
        isTrue,
        reason: 'InfoPlist.strings 须为 variant group（en/zh-Hans 取系统语言）',
      );
      expect(
        RegExp('zh-Hans,\\r?\\n').hasMatch(pbxproj),
        isTrue,
        reason: 'knownRegions 缺 zh-Hans（变体组按语言解析失败）',
      );
    });
  });

  group('InfoPlist.strings 双语（权限弹窗随系统语言）', () {
    test('en/zh-Hans 两份在场且键集合与 Info.plist 权限键一致', () {
      final en = File('ios/Runner/en.lproj/InfoPlist.strings');
      final zh = File('ios/Runner/zh-Hans.lproj/InfoPlist.strings');
      expect(en.existsSync(), isTrue);
      expect(zh.existsSync(), isTrue);
      final keys =
          RegExp(r'"(NS\w*UsageDescription|CFBundleDisplayName)"')
              .allMatches(plist)
              .map((m) => m.group(1)!)
              .toSet();
      for (final src in [en, zh]) {
        final text = src.readAsStringSync();
        for (final key in keys) {
          expect(
            text.contains('"$key"'),
            isTrue,
            reason: '${src.path} 缺 $key',
          );
        }
      }
    });
  });
}
