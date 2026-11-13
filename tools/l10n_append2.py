# Append l10n completion batch 2 (interpolation patterns, ~40 entries)
# to custom_l10n.dart. 2026-11-13.
import io
import re

p = 'app/lib/core/custom_l10n.dart'
s = io.open(p, encoding='utf-8').read()

EXACT = """
  // l10n 补全批 2（2026-11-13）：批量保存/预览新功能文案。
  '全部保存到下载目录': 'Save all to Downloads',
  '正在批量保存…': 'Batch saving…',
  '已取消': 'Cancelled',
"""

PATTERNS = r"""
  // l10n 补全批 2（2026-11-13）：插值串 pattern 全量补（缺口 50 条）。
  _L10nPattern(RegExp(r'^(\d+) 个文件\s*$'), '{n} files', {'n': 1}),
  _L10nPattern(RegExp(r'^(\d+) 秒后自动结束$'), 'Auto-dismiss in {n}s', {'n': 1}),
  _L10nPattern(RegExp(r'^(.+) (\d+) 个$'), '{label}: {n}', {'label': 1, 'n': 2}),
  _L10nPattern(RegExp(r'^(.+) (\d+) 个，(\d+) 个失败：([\s\S]+)$'), '{label}: {ok} done, {failed} failed: {preview}', {'label': 1, 'ok': 2, 'failed': 3, 'preview': 4}),
  _L10nPattern(RegExp(r'^(\d+) 项$'), '{n} items', {'n': 1}),
  _L10nPattern(RegExp(r'^([\s\S]+) API key（整理用）$'), '{provider} API key (for refining)', {'provider': 1}),
  _L10nPattern(RegExp(r'^(\d+) 个子代理$'), '{n} sub-agents', {'n': 1}),
  _L10nPattern(RegExp(r'^「([\s\S]+)」将在下条消息时生效（会话正忙）$'), '"{mode}" takes effect with the next message (session is busy)', {'mode': 1}),
  _L10nPattern(RegExp(r'^「([\s\S]+)」超过 20MB 上限$'), '"{name}" exceeds the 20MB limit', {'name': 1}),
  _L10nPattern(RegExp(r'^产物（(\d+)）$'), 'Artifacts ({n})', {'n': 1}),
  _L10nPattern(RegExp(r'^以 ([\s\S]+) 拉取$'), 'Pulling with {account}', {'account': 1}),
  _L10nPattern(RegExp(r'^其他电脑（(\d+)）$'), 'Other computers ({n})', {'n': 1}),
  _L10nPattern(RegExp(r'^删除「([\s\S]+)」\?$'), 'Delete "{name}"?', {'name': 1}),
  _L10nPattern(RegExp(r'^删除账号 ([\s\S]+)\?$'), 'Delete account {label}?', {'label': 1}),
  _L10nPattern(RegExp(r'^加载更多失败：([\s\S]+)$'), 'Failed to load more: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^后台工作 · (\d+)$'), 'Background tasks · {n}', {'n': 1}),
  _L10nPattern(RegExp(r'^回到本回合开始失败：([\s\S]+)$'), 'Failed to jump to the start of this turn: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^将把本轮对 (\d+) 个文件的修改恢复到本轮开始前$'), 'Restore changes to {n} files back to before this turn', {'n': 1}),
  _L10nPattern(RegExp(r'^将把本轮对 (\d+) 个文件的修改恢复到本轮开始前（含「([\s\S]+)」；撤销按文件逐个进行，越过安全边界的文件会被跳过）。聊天记录不受影响。$'), 'Restore changes to {n} files back to before this turn (including "{path}"; undo is per file — files past the safety boundary are skipped). Chat history is unaffected.', {'n': 1, 'path': 2}),
  _L10nPattern(RegExp(r'^将消耗 1 次重置机会，立即重置([\s\S]+)的已用额度。$'), 'Uses 1 reset to immediately refill the used quota for {label}.', {'label': 1}),
  _L10nPattern(RegExp(r'^工作区 Hook 审核 · (\d+) 项待信任$'), 'Workspace hook review · {n} pending trust', {'n': 1}),
  _L10nPattern(RegExp(r'^已上传 · ([\s\S]+)$'), 'Uploaded · {size}', {'size': 1}),
  _L10nPattern(RegExp(r'^已切换到 ([\s\S]+)$'), 'Switched to {branch}', {'branch': 1}),
  _L10nPattern(RegExp(r'^已归档的任务 \((\d+)\)$'), 'Archived tasks ({n})', {'n': 1}),
  _L10nPattern(RegExp(r'^应答发送失败，请重试：([\s\S]+)$'), 'Failed to send the response. Try again: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^排队中 \((\d+)\)$'), 'Queued ({n})', {'n': 1}),
  _L10nPattern(RegExp(r'^操作未生效（([\s\S]+)）$'), 'Operation did not take effect ({detail})', {'detail': 1}),
  _L10nPattern(RegExp(r'^新建于 ([\s\S]+)$'), 'Created in {workspace}', {'workspace': 1}),
  _L10nPattern(RegExp(r'^明细加载失败：([\s\S]+)$'), 'Failed to load details: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^显示全部 (\d+) 行$'), 'Show all {n} lines', {'n': 1}),
  _L10nPattern(RegExp(r'^最多 (\d+) 个附件$'), 'Up to {n} attachments', {'n': 1}),
  _L10nPattern(RegExp(r'^最近错误：([\s\S]+)$'), 'Last error: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^有 (\d+) 个档案数据损坏已跳过（重扫该电脑可恢复）$'), '{n} corrupted profiles skipped (re-scan the computer to recover)', {'n': 1}),
  _L10nPattern(RegExp(r'^正在切换到 ([\s\S]+)…$'), 'Switching to {branch}…', {'branch': 1}),
  _L10nPattern(RegExp(r'^正在创建项目 ([\s\S]+)…$'), 'Creating project {name}…', {'name': 1}),
  _L10nPattern(RegExp(r'^目录获取失败：([\s\S]+)$'), 'Failed to get the directory: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^等 (\d+) 项$'), '{n} items in total', {'n': 1}),
  _L10nPattern(RegExp(r'^编辑失败：([\s\S]+)$'), 'Edit failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^进入新项目失败：([\s\S]+)（可从项目列表手动打开）$'), 'Failed to enter the new project ({detail}) — open it manually from the project list', {'detail': 1}),
  _L10nPattern(RegExp(r'^重命名失败：([\s\S]+)$'), 'Rename failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^重置失败：([\s\S]+)$'), 'Reset failed: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^重置([\s\S]+)？$'), 'Reset {label}?', {'label': 1}),
  _L10nPattern(RegExp(r'^链接：([\s\S]+)$'), 'Link: {url}', {'url': 1}),
  _L10nPattern(RegExp(r'^页面加载失败（([\s\S]+)）$'), 'Page failed to load ({detail})', {'detail': 1}),
  _L10nPattern(RegExp(r'^顺序保存失败，请重试：([\s\S]+)$'), 'Sequential save failed. Try again: {detail}', {'detail': 1}),
  _L10nPattern(RegExp(r'^验证 (\d+)/(\d+)$'), 'Verified {passed}/{total}', {'passed': 1, 'total': 2}),
  _L10nPattern(RegExp(r'^该工作区有 (\d+) 个运行中任务。切分支对整个工作区全局生效（官方语义），运行中的会话也会受影响。确定切换到「([\s\S]+)」\?$'), 'This workspace has {n} running tasks. Branch switching affects the whole workspace (official semantics), including running sessions. Switch to "{branch}"?', {'n': 1, 'branch': 2}),
  _L10nPattern(RegExp(r'^该电脑当前绑定账号 ([\s\S]+)，将改为 ([\s\S]+)。改绑后旧账号在此电脑上的连接会失效。$'), 'This computer is currently bound to account {from}; it will switch to {to}. Connections from the old account on this computer will stop working.', {'from': 1, 'to': 2}),
  _L10nPattern(RegExp(r'^该任务的目录不在项目「([\s\S]+)」的文件夹列表里。\n「([\s\S]+)」$'), 'The task directory is not in the folder list of project "{name}".\n"{path}"', {'name': 1, 'path': 2}),
  _L10nPattern(RegExp(r'^获取文件失败：([\s\S]+)$'), 'Failed to fetch file: {detail}', {'detail': 1}),
"""

anchor = "// l10n 补全批 2（2026-11-13）：批量保存/预览新功能文案。"
assert anchor not in s, 'batch 2 already applied'
s = s.replace("const Map<String, String> _customEn = <String, String>{",
              "const Map<String, String> _customEn = <String, String>{" + EXACT, 1)

pat_anchor = "_L10nPattern(RegExp(r'^附件读取失败：([\\s\\S]+)$'), 'Failed to read attachment: {detail}', {'detail': 1}),"
assert pat_anchor in s, 'pattern anchor not found'
s = s.replace(pat_anchor, pat_anchor + PATTERNS, 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('batch 2 appended')
