# v1.5.0 上游合并方案与执行记录（zcode-pocket v1.0.6 + v1.0.7）

> 合并范围：fork 点 `c4c4464` → 上游 `e2393a7`（9 commits，245 文件 +12897/-866）。
> 分支：`merge-upstream-1.0.7`，合并 commit `216a67a`。

## 一、上游带来什么

**官方 ZCode 3.18 协议增量**（上游已适配）：
- 新 RPC `getContextComposition`（上下文组成下钻，需桌面 3.18+）
- 新命令 `stopSubagent`（子代理逐条停止，strict 载荷，需桌面 3.18+）
- `resolveInteraction` 语义未变——ZPocket v1.4.0 快捷审批不受影响

**上游 v1.0.6 + v1.0.7 功能**：
| 功能 | 落点 |
| --- | --- |
| 上下文组成下钻 | `context_composition_page.dart`（用量卡入口） |
| 子代理逐条停止 | 子代理列表停止按钮（`stopSubagent`） |
| 会话永久删除 | `session_deletion_flow.dart`（PIN 三段防呆） |
| 工作流产物收集/分享 | `artifact_share.dart` + `share_flow.dart` + `companion/share` 通道 + FileProvider `artifacts/` |
| 提交配置溯源角标 | `user_config_badge` |
| 通知权限只读复查 | `checkPermission()`（冷启动复查，不误翻开关） |
| 应用锁材料原子化 | `ui_prefs` 单键 JSON + 旧两键异步迁移 + 损坏恢复出口 |
| 照片附件加固 | 4096px 尺寸/数量上限（image_picker ^1.2.4） |
| WebView 致命错误判定 | `webview_errors.dart` |
| 备份排除 | `backup_exclusion.dart` |
| 顶栏工作流一级入口 | 带运行中 run 计数（替代旧菜单槽位） |
| 用量页 Start Plan 死锁修复 | issue #13 |

## 二、冲突解决所有权（16 个冲突文件）

| 类别 | 决策 |
| --- | --- |
| README.md / CHANGELOG.md / README.zh-CN.md | 我方全胜（fork 身份独立） |
| 品牌名（app.dart / device_info.dart / custom_l10n 词条） | ZPocket |
| pubspec version | 我方 1.4.0 行（发布时升 1.5.0）+ 上游 image_picker |
| ui_prefs reads 索引 | **双 key 共存**：28=updateSource（我方保位，老用户数据兼容）、29=pinMaterial（上游后移）；消费端 `reads[28]→reads[29]` 错位修正 |
| settings 更新入口条件 | 融合 `!kInAppUpdateDisabled && ZpCapabilities.supportsSelfUpdate` |
| settings 更新源选择器 | 我方整块保留 |
| file_preview actions | 保存（我方）+ 分享（上游）共存；import 全并集 |
| conversation_page 工作流入口 | **取上游**（顶栏一级+计数；菜单槽位退役，避免死菜单项——`_onTaskMenu` 的 workflowRuns case 上游已删） |
| notification_service | 上游 checkPermission + 我方 actions 链路共存（抽象缝+实现类双侧验证） |
| MainActivity.kt | saveToDownloads（我方）+ companion/share（上游 59 行）共存于 `com.zpocket.mobile` |
| 测试 import | 我方包名 `zpocket` + 上游新增 import 合并（15 个上游新测试文件批量替换包名） |

Kotlin 包名分叉（`dev.zcodeapp.zcode_companion` → `com.zpocket.mobile`）：git rename 检测全数正确带走上游改动，合并后全仓库旧包名零残留。

## 三、验证记录

| 检查 | 结果 |
| --- | --- |
| flutter analyze | 0 error/warning（info 238→248，+10 条为上游自带） |
| flutter test 全量 | **1572 全绿**（基线 1422 + 上游 +150） |
| 自研守卫点名组 | 74 用例全绿（file_card/update/notify×4/wire_protocol/file_preview） |
| 旧包名残留 | 零 |
| l10n 重复键 | `'发送'` 一处，已除 |

**执行中的坑（复现与排除）**：
1. **dart test 增量编译缓存**：合并后首次全量跑 `relay_client_v1_test` F1 与 `reconnect_recovery_test` 各 1 例假红（旧编译产物混入新依赖图）。清 `.dart_tool/flutter_test*` 后全量重跑全绿；main worktree 对照排除代码因素。**今后大合并后必须先清测试缓存再跑全量。**
2. **ui_prefs 索引错位**：上游消费端自动合并后仍读 `reads[28]`（已是我方 updateSource 槽位）——静态合并不报错、运行时才错。位置索引式存储的合并要双向核对生产端与消费端。

## 四、批 5 发布清单（待用户真机验收后）

1. version → `1.5.0+<yyyymmdd>01`
2. `flutter build apk --release --split-per-abi` + SHA256
3. `tools/release.py` 清单 → nghqqa.cn + GitHub Release v1.5.0
4. 签名指纹 `f9ffa6fa…` 不变（keystore 未动）
5. 真机验收单：3.18.2 桌面 + 手机 1.5.0——①上下文下钻页 ②子代理逐条停止 ③会话永久删除 PIN 流 ④产物收集/分享 ⑤**旧功能回归**：快捷审批/文件下载/双通道更新源

## 五、后续合并策略

- 上游迭代保持活跃（1.0.7 后预计仍有 hotfix），**每次自研发版后尽快跟并**，分叉越深冲突越贵
- 与上游重叠的产物下载：双通道并存——上游走 agent 发布产物（workflow artifact 通道），ZPocket 走工作区直读（stat/readFileRange），场景互补
