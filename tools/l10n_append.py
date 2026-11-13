# Append l10n completion batch (52 exact entries + error-recovery
# patterns) to custom_l10n.dart. L10n completion batch, 2026-11-13.
import io

p = 'app/lib/core/custom_l10n.dart'
s = io.open(p, encoding='utf-8').read()

EXACT = """
  // l10n 补全批（2026-11-13 评审）：lib/ui 内 Text() 中文直出但词典
  // 缺失的 52 条（tools/l10n_missing.py 提取）。
  '上下文容量': 'Context capacity',
  '停止': 'Stop',
  '先规划再动手，可与权限档并行；随下条消息生效': 'Plan first, then act — runs alongside the permission mode and takes effect with the next message',
  '先连接工作区后才能刷新归档列表': 'Connect to the workspace before refreshing the archive list',
  '全部删除': 'Delete all',
  '全部展开': 'Expand all',
  '创建': 'Create',
  '删除定时任务': 'Delete scheduled task',
  '删除账号失败，请重试': 'Failed to delete the account. Try again',
  '刷新': 'Refresh',
  '压缩': 'Compact',
  '发送': 'Send',
  '取消等待': 'Cancel queue wait',
  '在电脑 ZCodeProject 下创建并进入': 'Create it under the desktop ZCodeProject and open it',
  '复制会话 ID': 'Copy session ID',
  '子智能体会话为只读，模式跟随主会话': 'Sub-agent sessions are read-only; the mode follows the main session',
  '子智能体定义文件将被删除，不可恢复。': 'The sub-agent definition file will be deleted. This cannot be undone.',
  '将核销一次重置机会，把 5 小时窗口额度恢复满额。': 'Uses one reset to refill the 5-hour window quota.',
  '工作区切换未完成，请稍后从项目列表打开': 'Workspace switch unfinished — open it later from the project list',
  '已切换提供商——API key 不通用，请更新为新平台的 key': 'Provider switched — API keys do not carry over. Update the key for the new platform',
  '已删除': 'Deleted',
  '已归档的任务': 'Archived tasks',
  '已禁用': 'Disabled',
  '已获取凭据，但保存到本机连续失败。请重试；反复失败请反馈问题。': 'Credentials received, but saving to this device keeps failing. Try again; if it keeps failing, please report the issue.',
  '已重置，额度刷新中': 'Reset done — quota refreshing',
  '当前没有后台工作': 'No background tasks right now',
  '找不到该任务所属的工作区，可能已被桌面端移除': 'Workspace for this task not found — it may have been removed on the desktop',
  '文件选择器不可用': 'File picker unavailable',
  '最近': 'Recent',
  '有一条发送失败的消息已暂存': 'A message that failed to send is saved as a draft',
  '权限': 'Permissions',
  '模型目录暂不可用（会话激活后自动恢复）。': 'Model catalog temporarily unavailable (restores once the session is active).',
  '模式': 'Mode',
  '此工作区暂无技能（桌面端安装后可用）': 'No skills in this workspace yet (install them on the desktop first)',
  '没有输出。': 'No output.',
  '添加': 'Add',
  '知道了': 'Got it',
  '确认': 'Confirm',
  '编辑消息': 'Edit message',
  '计划模式': 'Plan mode',
  '计划模式已随权限切换关闭（重新打开请用计划开关）': 'Plan mode was turned off with the permission switch (re-enable it with the plan toggle)',
  '该任务不在当前工作区，可能已被移除': 'This task is not in the current workspace — it may have been removed',
  '该电脑还在重连，稍后再试': 'This computer is still reconnecting — try again shortly',
  '该目录项缺少供应商信息，无法挂起': 'This catalog entry is missing provider info; it cannot be queued',
  '跳过': 'Skip',
  '重发': 'Resend',
  '重发后，这条消息之后的所有回复将被丢弃并重新生成。': 'Resending discards all replies after this message and regenerates them.',
  '重命名任务': 'Rename task',
  '重新登录': 'Sign in again',
  '重新获取目录': 'Reload catalog',
  '重置额度？': 'Reset quota?',
  '（本文件无文本 hunk）': '(no text hunks in this file)',
"""

PATTERNS = """
  // l10n 补全批（2026-11-13）：错误恢复/反馈类插值串 pattern。
  _L10nPattern(RegExp(r'^信任失败：([\\s\\S]+)$'), 'Trust failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^切换失败，请重试：([\\s\\S]+)$'), 'Switch failed. Try again: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^创建失败，请重试：([\\s\\S]+)$'), 'Create failed. Try again: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^创建失败：([\\s\\S]+)$'), 'Create failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^删除失败：([\\s\\S]+)$'), 'Delete failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^加载失败：([\\s\\S]+)$'), 'Failed to load: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^回滚失败：([\\s\\S]+)$'), 'Rollback failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^回滚预检失败：([\\s\\S]+)$'), 'Rollback precheck failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^打开任务失败：([\\s\\S]+)$'), 'Failed to open task: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^停止未生效：([\\s\\S]+)$'), 'Stop did not take effect: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^压缩失败：([\\s\\S]+)$'), 'Compaction failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^操作失败：([\\s\\S]+)$'), 'Operation failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^技能列表获取失败：([\\s\\S]+)$'), 'Failed to fetch skills: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^分支信息加载失败：([\\s\\S]+)$'), 'Failed to load branch info: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^信任未生效（([\\s\\S]+)）——审核已更新，请返回重进$'), 'Trust not in effect ({reason}) — the review was updated, go back and re-enter', {'reason': 1}),
  _L10nPattern(RegExp(r'^切换失败（([\\s\\S]+)）；已挂起，将随下条消息提交$'), 'Switch failed ({detail}); queued and will submit with the next message', {'detail': 1}),
  _L10nPattern(RegExp(r'^刷新于 ([\\s\\S]+)$'), 'Refreshed at {time}', {'time': 1}),
  _L10nPattern(RegExp(r'^后台工作（(\\d+) 项）$'), 'Background tasks ({n})', {'n': 1}),
  _L10nPattern(RegExp(r'^已更改 (\\d+) 个文件$'), 'Changed {n} files', {'n': 1}),
"""

anchor = "  // l10n 补全批（2026-11-13 评审）：lib/ui 内 Text() 中文直出但词典"
assert anchor not in s, 'batch already applied'
s = s.replace("const Map<String, String> _customEn = {", "const Map<String, String> _customEn = {" + EXACT, 1)

pat_anchor = "_L10nPattern(RegExp(r'^渲染失败：([\\s\\S]+)$'), 'Failed to render: {detail}', {'detail': 1}),"
assert pat_anchor in s, 'pattern anchor not found'
s = s.replace(pat_anchor, pat_anchor + PATTERNS, 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('custom_l10n.dart: 52 exact entries + 19 patterns appended')
