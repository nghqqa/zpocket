// iCloud 备份排除（早前批次）。
//
// 背景：发布面审查指出「关于页承诺云备份已关闭」与实际不符——iOS 上
// Application Support（档案/缓存/草稿库）与 Documents 默认都会进 iCloud
// 备份与整机迁移；Android 侧 allowBackup=false 早已全局排除，iOS 缺
// 对位（审查中 11/16 命中）。
//
// 语义：iOS 启动时对应用支持/文档两目录整树 setResourceValues(
// isExcludedFromBackup=true)（目录级设置=子树排除，含后续新建文件）；
// Keychain 数据默认不进 iCloud 备份（kSecAttrSynchronizable 未设），
// 无需处理。失败只留日志——备份面绝不阻塞主流程。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('companion/appinfo');

/// 测试缝：目录提供器覆写（真机不可注入）。
@visibleForTesting
var debugDirProviders = <String, Future<String> Function()>{
  'getApplicationSupportDirectory': () async =>
      (await getApplicationSupportDirectory()).path,
  'getApplicationDocumentsDirectory': () async =>
      (await getApplicationDocumentsDirectory()).path,
};

/// 对 [dirs] 全部路径发起备份排除（幂等，启动一次调用）。
Future<void> excludeDirsFromICloudBackup() async {
  for (final entry in debugDirProviders.entries) {
    try {
      final path = await entry.value();
      final ok = await _channel.invokeMethod<bool>(
            'excludeFromiCloudBackup',
            {'path': path},
          ) ??
          false;
      if (!ok) {
        debugPrint('[backup] exclude failed: $path');
      }
    } catch (e) {
      debugPrint('[backup] ${entry.key} unavailable: $e');
    }
  }
}
