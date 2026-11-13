import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// ZPocket 启动图标守护（v5 艺术品管线，2026-11-13 重写）。
///
/// 图标源为 tools/icon/artwork-1024.png（用户提供的绿色折带 "Z."），
/// 由 tools/gen_icon.py 缩放为五档 mipmap。本测试钉死该设计的不变量：
/// 全尺寸不透明、四角近黑（艺术底非纯 0）、192 母版亮部字标
/// （任意通道 >180）满版且居中。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, int>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  test('启动图标五档均为不透明底、四角近黑', () async {
    for (final entry in sizes.entries) {
      final file = File(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
      );
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      codec.dispose();
      expect(image.width, entry.value, reason: '${entry.key} 宽度');
      expect(image.height, entry.value, reason: '${entry.key} 高度');

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      for (var i = 3; i < pixels.length; i += 4) {
        expect(pixels[i], 255, reason: '${entry.key} 第 ${i ~/ 4} 像素透明度');
      }

      for (final corner in <(int, int)>[
        (0, 0),
        (image.width - 1, 0),
        (0, image.height - 1),
        (image.width - 1, image.height - 1),
      ]) {
        final offset = (corner.$2 * image.width + corner.$1) * 4;
        final px = pixels.sublist(offset, offset + 4);
        expect(px[3], 255, reason: '${entry.key} 四角不透明');
        expect(
          px[0] <= 12 && px[1] <= 12 && px[2] <= 12,
          true,
          reason: '${entry.key} 四角必须近黑（实际 $px）',
        );
      }
      image.dispose();
    }
  });

  test('Z. 字标满版居中（ZPocket v5 品牌钉死）', () async {
    final file = File(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    );
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    codec.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = data!.buffer.asUint8List();

    var minX = image.width;
    var minY = image.height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final offset = (y * image.width + x) * 4;
        final r = pixels[offset];
        final g = pixels[offset + 1];
        final b = pixels[offset + 2];
        // 亮部像素（任意通道 >180）——绿色折带与青绿下划线均命中。
        if (r > 180 || g > 180 || b > 180) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    expect(maxX, greaterThanOrEqualTo(0), reason: '画布中必须存在亮部字标');
    expect(maxX - minX + 1, greaterThanOrEqualTo(70), reason: '字标宽度');
    expect(maxY - minY + 1, greaterThanOrEqualTo(80), reason: '字标高度');
    expect((minX + maxX) / 2, closeTo(96, 4), reason: '水平居中（含下划线的构图中心）');
    expect((minY + maxY) / 2, closeTo(96, 4), reason: '垂直居中');
    image.dispose();
  });
}
