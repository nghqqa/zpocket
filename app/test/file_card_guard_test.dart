import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 文件摘要卡守卫（2026-11-13 评审 P0/P1 修复钉死）：
/// 1. 文件名提取必须双分隔符——Windows 反斜杠路径此前 split('/')
///    切不开，8 行全部同形双截断不可辨识（截图实证）；
/// 2. 行尾下载钮触控目标 ≥44dp（30dp 低于安卓下限，且会话页族在
///    design_guard_test 的守卫盲区里，靠本文件补位）；
/// 3. 批量保存入口与静默 Downloads 通道接线存在。
void main() {
  final src =
      File('lib/ui/conversation_file_summary_card.dart').readAsStringSync();

  test('文件名/相对路径提取走双分隔符正则', () {
    expect(src.contains('String _fileNameOf(String path)'), isTrue,
        reason: '文件名提取独立成函数（标题与保存名共用）');
    // 源码字节级断言：r'[\\/]'（双分隔符字符类）。
    expect(src.contains(r"RegExp(r'[\\/]')"), isTrue,
        reason: r'必须用 [\\/] 双分隔符切（split("/") 对 Windows 路径失效）');
    expect(src.contains('_relativeDisplayPath'), isTrue,
        reason: '副行剥 workspace 前缀显示相对路径');
  });

  test('下载钮触控目标 ≥44dp', () {
    final m = RegExp(
      r'constraints: const BoxConstraints\(\s*minWidth: (\d+),\s*minHeight: (\d+),',
    ).firstMatch(src);
    expect(m, isNotNull, reason: '下载钮必须显式声明触控约束');
    final w = int.parse(m!.group(1)!);
    final h = int.parse(m.group(2)!);
    expect(w, greaterThanOrEqualTo(44), reason: '宽度 ≥44');
    expect(h, greaterThanOrEqualTo(44), reason: '高度 ≥44');
  });

  test('批量保存入口 + 静默 Downloads 通道 + 可取消', () {
    expect(src.contains("ValueKey('file-summary-save-all')"), isTrue,
        reason: '全部保存入口存在');
    expect(src.contains('_saveAllToPhone'), isTrue);
    expect(src.contains('saveBytesToDownloadsFolder'), isTrue,
        reason: '批量走静默 Downloads 通道（不逐个弹 SAF）');
    expect(src.contains('cancelled: () => cancelled'), isTrue,
        reason: '分段拉取可取消（弱网防冻结）');
  });
}
