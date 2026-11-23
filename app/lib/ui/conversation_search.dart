import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../core/payload_guard.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';
import '../transport/conversation.dart';
import 'turn_model.dart';

const int conversationSearchRowLimit = 1200;
const int _kMaxRegexMatchesPerRow = 200;
const int _kMaxTotalSearchMatches = 2000;
const int _kMaxRegexScanLength = 200000;
final RegExp _searchWhitespaceRe = RegExp(r'\s+');

enum ConversationSearchKind { user, assistant, tool, reasoning }

({int end, bool variableRepeat})? _readBracedQuantifier(
  String pattern,
  int start,
) {
  if (start >= pattern.length || pattern.codeUnitAt(start) != 0x7B /* { */) {
    return null;
  }
  var i = start + 1;
  final minStart = i;
  while (i < pattern.length) {
    final c = pattern.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) break;
    i++;
  }
  if (i == minStart) return null;
  final minCount = int.tryParse(pattern.substring(minStart, i));
  if (minCount == null) return null;
  var hasComma = false;
  int? maxCount = minCount;
  if (i < pattern.length && pattern.codeUnitAt(i) == 0x2C /* , */) {
    hasComma = true;
    i++;
    final maxStart = i;
    while (i < pattern.length) {
      final c = pattern.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) break;
      i++;
    }
    maxCount = i == maxStart
        ? null
        : int.tryParse(pattern.substring(maxStart, i));
  }
  if (i >= pattern.length || pattern.codeUnitAt(i) != 0x7D /* } */) {
    return null;
  }
  final variableRepeat =
      hasComma && (maxCount == null || (maxCount > minCount && maxCount > 1));
  return (end: i, variableRepeat: variableRepeat);
}

/// 预检明显的高危回溯正则（ReDoS）：
/// 1) 嵌套量词：`(a+)+`、`(.*)+`、`(.+)*`、`(\w+){2,}`；
/// 2) 量化分支交替：`(a|aa)+$`、`(\s|.)*END`；
/// 3) 反向引用带量词：`(a+)\1+`、`(?<x>a+)\k<x>*`。
/// 线性扫描避开转义与字符类内的字面符号。
bool isPotentiallyUnsafeRegex(String pattern) {
  final groupHasQuantifier = <bool>[];
  final groupHasAlternation = <bool>[];
  var inCharClass = false;

  bool consumeTrailingQuantifier(int afterIndex) {
    if (afterIndex >= pattern.length) return false;
    final next = pattern.codeUnitAt(afterIndex);
    if (next == 0x2B /* + */ || next == 0x2A /* * */) return true;
    if (next == 0x7B /* { */) {
      final braced = _readBracedQuantifier(pattern, afterIndex);
      return braced != null && braced.variableRepeat;
    }
    return false;
  }

  for (var i = 0; i < pattern.length; i++) {
    final c = pattern.codeUnitAt(i);
    if (c == 0x5C /* \ */) {
      if (i + 1 < pattern.length) {
        final esc = pattern.codeUnitAt(i + 1);
        if (!inCharClass && esc >= 0x31 && esc <= 0x39 /* \1..\9 */) {
          var end = i + 1;
          while (end + 1 < pattern.length) {
            final d = pattern.codeUnitAt(end + 1);
            if (d < 0x30 || d > 0x39) break;
            end++;
          }
          if (consumeTrailingQuantifier(end + 1)) return true;
          if (groupHasQuantifier.isNotEmpty) {
            groupHasQuantifier[groupHasQuantifier.length - 1] = true;
          }
          i = end;
          continue;
        }
        if (!inCharClass &&
            esc == 0x6B /* \k<name> */ &&
            i + 2 < pattern.length &&
            pattern.codeUnitAt(i + 2) == 0x3C /* < */) {
          final close = pattern.indexOf('>', i + 3);
          if (close > i + 3) {
            if (consumeTrailingQuantifier(close + 1)) return true;
            if (groupHasQuantifier.isNotEmpty) {
              groupHasQuantifier[groupHasQuantifier.length - 1] = true;
            }
            i = close;
            continue;
          }
        }
      }
      i++;
      continue;
    }
    if (inCharClass) {
      if (c == 0x5D /* ] */) inCharClass = false;
      continue;
    }
    if (c == 0x5B /* [ */) {
      inCharClass = true;
      continue;
    }
    if (c == 0x28 /* ( */) {
      groupHasQuantifier.add(false);
      groupHasAlternation.add(false);
      continue;
    }
    if (c == 0x7C /* | */) {
      if (groupHasAlternation.isNotEmpty) {
        groupHasAlternation[groupHasAlternation.length - 1] = true;
      }
      continue;
    }
    if (c == 0x29 /* ) */) {
      if (groupHasQuantifier.isEmpty) continue;
      final innerHasQuantifier = groupHasQuantifier.removeLast();
      final innerHasAlternation = groupHasAlternation.removeLast();
      var outerQuantified = false;
      if (i + 1 < pattern.length) {
        final next = pattern.codeUnitAt(i + 1);
        if (next == 0x2B /* + */ || next == 0x2A /* * */) {
          outerQuantified = true;
          i++;
        } else if (next == 0x7B /* { */) {
          final braced = _readBracedQuantifier(pattern, i + 1);
          if (braced != null) {
            outerQuantified = braced.variableRepeat;
            i = braced.end;
          }
        }
      }
      if ((innerHasQuantifier || innerHasAlternation) && outerQuantified) {
        return true;
      }
      if (groupHasQuantifier.isNotEmpty &&
          (innerHasQuantifier || outerQuantified)) {
        groupHasQuantifier[groupHasQuantifier.length - 1] = true;
      }
      if (groupHasAlternation.isNotEmpty && innerHasAlternation) {
        groupHasAlternation[groupHasAlternation.length - 1] = true;
      }
      continue;
    }
    if (c == 0x2B /* + */ || c == 0x2A /* * */) {
      if (groupHasQuantifier.isNotEmpty) {
        groupHasQuantifier[groupHasQuantifier.length - 1] = true;
      }
      continue;
    }
    if (c == 0x7B /* { */) {
      final braced = _readBracedQuantifier(pattern, i);
      if (braced != null) {
        if (braced.variableRepeat && groupHasQuantifier.isNotEmpty) {
          groupHasQuantifier[groupHasQuantifier.length - 1] = true;
        }
        i = braced.end;
      }
    }
  }
  return false;
}

/// 空格分词（去空、去重、保序；长度稳定折叠）。
List<String> splitSearchTerms(String query) {
  final trimmed = foldCaseStable(query.trim());
  if (trimmed.isEmpty) return const [];
  final seen = <String>{};
  final out = <String>[];
  for (final part in trimmed.split(_searchWhitespaceRe)) {
    if (part.isNotEmpty && seen.add(part)) {
      out.add(part);
    }
  }
  return out;
}

/// 编译正则搜索式（大小写不敏感、多行、unicode 防代理对劈裂）；
/// 命中嵌套量词 ReDoS 预检或语法非法时返回错误描述。
({RegExp? regex, String? error}) compileSearchRegex(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return (regex: null, error: null);
  if (isPotentiallyUnsafeRegex(trimmed)) {
    return (regex: null, error: '正则表达式过于复杂');
  }
  try {
    return (
      regex: RegExp(trimmed, caseSensitive: false, multiLine: true, unicode: true),
      error: null,
    );
  } on FormatException catch (e) {
    return (regex: null, error: e.message);
  }
}

String _clipRegexScanSource(String source) {
  if (source.length <= _kMaxRegexScanLength) return source;
  var end = _kMaxRegexScanLength;
  final last = source.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return source.substring(0, end);
}

List<({int start, int end})> _findLiteralRanges(
  String haystack,
  String needle,
) {
  final ranges = <({int start, int end})>[];
  var from = 0;
  while (from <= haystack.length - needle.length) {
    final start = haystack.indexOf(needle, from);
    if (start < 0) break;
    ranges.add((start: start, end: start + needle.length));
    from = start + needle.length;
  }
  return ranges;
}

/// 查找 [source] 中全部高亮区间（供高亮渲染与索引复用）。
/// - [useRegex]=false：空格多词优先连续短语（与计数一致），无短语时按
///   AND 语义返回合并后的非重叠命中区间；单词与旧字面子串完全等价；
/// - [useRegex]=true：大小写不敏感正则，跳过零宽匹配，单行扫描窗口上限
///   200,000 字符且命中上限 200 处。
List<({int start, int end})> findSearchMatchRanges(
  String source,
  String query, {
  bool useRegex = false,
  RegExp? compiledRegex,
}) {
  if (source.isEmpty) return const [];
  if (useRegex) {
    final re = compiledRegex ?? compileSearchRegex(query).regex;
    if (re == null) return const [];
    final scanSource = _clipRegexScanSource(source);
    final ranges = <({int start, int end})>[];
    for (final m in re.allMatches(scanSource)) {
      if (m.end <= m.start) continue;
      ranges.add((start: m.start, end: m.end));
      if (ranges.length >= _kMaxRegexMatchesPerRow) break;
    }
    return ranges;
  }
  final trimmed = query.trim();
  final terms = splitSearchTerms(trimmed);
  if (terms.isEmpty) return const [];
  final haystack = foldCaseStable(source);
  if (terms.length == 1) {
    return _findLiteralRanges(haystack, terms.first);
  }
  // 与 buildConversationSearchMatches 短语优先语义对齐：若完整连续短语
  // 命中，仅高亮连续短语本身，不再把同条后面的零散分词也标亮。
  final phrase = foldCaseStable(trimmed);
  if (haystack.contains(phrase)) {
    return _findLiteralRanges(haystack, phrase);
  }
  // 多词 AND：所有词都必须存在，否则整条不命中。
  final raw = <({int start, int end})>[];
  for (final term in terms) {
    final found = _findLiteralRanges(haystack, term);
    if (found.isEmpty) return const [];
    raw.addAll(found);
  }
  raw.sort((a, b) {
    final cmp = a.start.compareTo(b.start);
    return cmp != 0 ? cmp : a.end.compareTo(b.end);
  });
  final merged = <({int start, int end})>[];
  for (final r in raw) {
    if (merged.isEmpty || r.start > merged.last.end) {
      merged.add(r);
    } else if (r.end > merged.last.end) {
      merged[merged.length - 1] = (start: merged.last.start, end: r.end);
    }
  }
  return merged;
}

class ConversationSearchMatch {
  final int rowId;
  final int? turnId;
  final String anchorKey;
  final ConversationSearchKind kind;
  final int occurrence;
  final String sourceText;
  final int start;
  final int end;

  const ConversationSearchMatch({
    required this.rowId,
    required this.turnId,
    required this.anchorKey,
    required this.kind,
    required this.occurrence,
    required this.sourceText,
    required this.start,
    required this.end,
  });

  String get identity => '$rowId:${kind.name}:$occurrence';

  String get snippet {
    final from = math.max(0, start - 42);
    final to = math.min(sourceText.length, end + 72);
    final body = sourceText
        .substring(from, to)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${from > 0 ? '…' : ''}$body${to < sourceText.length ? '…' : ''}';
  }
}

String? _toolSearchText(Map<String, dynamic> row) {
  final parts = <String>[];
  final name = '${row['toolName'] ?? row['name'] ?? ''}'.trim();
  if (name.isNotEmpty) parts.add(name);
  final input = toolInputArgs(row);
  if (input != null) {
    parts.add(jsonEncode(input));
  } else {
    final raw = '${row['inputText'] ?? ''}'.trim();
    if (raw.isNotEmpty) parts.add(raw);
  }
  final error = row['error'];
  if (error is Map && '${error['message'] ?? ''}'.trim().isNotEmpty) {
    parts.add('${error['message']}'.trim());
  } else {
    final status = '${row['status'] ?? ''}';
    final running = status == 'running' || status == 'inputStreaming';
    var added = false;
    if (running) {
      final preview = row['outputPreview'];
      if (preview is Map && '${preview['fullText'] ?? ''}'.trim().isNotEmpty) {
        parts.add('${preview['fullText']}'.trim());
        added = true;
      }
    }
    if (!added) {
      final output = row['output'];
      if (output is Map) {
        final text = '${output['text'] ?? ''}'.trim();
        if (text.isNotEmpty) {
          parts.add(text);
          added = true;
        } else {
          final display = output['display'];
          if (display is Map && display['kind'] == 'bash_output') {
            final bash = '${display['output'] ?? ''}'.trim();
            if (bash.isNotEmpty) parts.add(bash);
          }
        }
      }
    }
  }
  if (parts.isEmpty) return null;
  return parts.join('\n');
}

String? _searchTextOf(
  Map<String, dynamic> row, {
  required bool includeReasoning,
}) => switch ('${row['kind']}') {
  'userInput' || 'assistantText' => '${row['text'] ?? ''}',
  'toolCall' => _toolSearchText(row),
  'reasoning' when includeReasoning => '${row['text'] ?? ''}',
  _ => null,
};

ConversationSearchKind? _searchKindOf(
  Map<String, dynamic> row, {
  required bool includeReasoning,
}) => switch ('${row['kind']}') {
  'userInput' => ConversationSearchKind.user,
  'assistantText' => ConversationSearchKind.assistant,
  'toolCall' => ConversationSearchKind.tool,
  'reasoning' when includeReasoning => ConversationSearchKind.reasoning,
  _ => null,
};

/// 主会话的提问/回复加上工具内容；[includeReasoning]=true 时同步索引思考块。
/// - 默认模式：大小写不敏感，空格拆分为多词 AND 语义（单词与旧字面一致）；
/// - [useRegex]=true：大小写不敏感正则匹配（非法正则返回空）。
List<ConversationSearchMatch> buildConversationSearchMatches(
  List<ChatItem> items,
  String query, {
  bool useRegex = false,
  bool includeReasoning = false,
  RegExp? compiledRegex,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  RegExp? resolvedRegex = compiledRegex;
  List<String> terms = const [];
  if (useRegex) {
    resolvedRegex ??= compileSearchRegex(trimmed).regex;
    if (resolvedRegex == null) return const [];
  } else {
    terms = splitSearchTerms(trimmed);
    if (terms.isEmpty) return const [];
  }
  final matches = <ConversationSearchMatch>[];
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    final anchorKey = chatItemKey(item, index);
    final rows = switch (item) {
      UserItem(:final row) => [row],
      TurnBarItem(:final work) => work.work,
      _ => const <Map<String, dynamic>>[],
    };
    final turnId = item is TurnBarItem
        ? intOf(item.work.header?['rowId'])
        : null;
    for (final row in rows) {
      final rowId = intOf(row['rowId']);
      final kind = _searchKindOf(row, includeReasoning: includeReasoning);
      final source = _searchTextOf(row, includeReasoning: includeReasoning);
      if (rowId == null || rowId < 0 || kind == null || source == null) {
        continue;
      }
      if (useRegex) {
        final ranges = findSearchMatchRanges(
          source,
          trimmed,
          useRegex: true,
          compiledRegex: resolvedRegex,
        );
        for (var occ = 0; occ < ranges.length; occ++) {
          final r = ranges[occ];
          matches.add(
            ConversationSearchMatch(
              rowId: rowId,
              turnId: turnId,
              anchorKey: anchorKey,
              kind: kind,
              occurrence: occ,
              sourceText: source,
              start: r.start,
              end: r.end,
            ),
          );
          if (matches.length >= _kMaxTotalSearchMatches) return matches;
        }
        continue;
      }
      final haystack = foldCaseStable(source);
      if (terms.length == 1) {
        final needle = terms.first;
        var occ = 0;
        var from = 0;
        while (from <= haystack.length - needle.length) {
          final start = haystack.indexOf(needle, from);
          if (start < 0) break;
          matches.add(
            ConversationSearchMatch(
              rowId: rowId,
              turnId: turnId,
              anchorKey: anchorKey,
              kind: kind,
              occurrence: occ,
              sourceText: source,
              start: start,
              end: start + needle.length,
            ),
          );
          occ++;
          from = start + needle.length;
          if (matches.length >= _kMaxTotalSearchMatches) return matches;
        }
        continue;
      }
      // 多词模式：①若完整短语本身连续出现，优先按连续短语逐次计（保持与
      // 旧带空格字面短语搜索 100% 一致的计数直觉）；②否则走空格多词 AND，
      // 全部词都存在时按每条消息 1 次定位（锚定最早出现词，渲染层高亮全词）。
      final phrase = foldCaseStable(trimmed);
      if (haystack.contains(phrase)) {
        var occ = 0;
        var from = 0;
        while (from <= haystack.length - phrase.length) {
          final start = haystack.indexOf(phrase, from);
          if (start < 0) break;
          matches.add(
            ConversationSearchMatch(
              rowId: rowId,
              turnId: turnId,
              anchorKey: anchorKey,
              kind: kind,
              occurrence: occ,
              sourceText: source,
              start: start,
              end: start + phrase.length,
            ),
          );
          occ++;
          from = start + phrase.length;
          if (matches.length >= _kMaxTotalSearchMatches) return matches;
        }
        continue;
      }
      final ranges = findSearchMatchRanges(source, trimmed, useRegex: false);
      if (ranges.isNotEmpty) {
        final first = ranges.first;
        matches.add(
          ConversationSearchMatch(
            rowId: rowId,
            turnId: turnId,
            anchorKey: anchorKey,
            kind: kind,
            occurrence: 0,
            sourceText: source,
            start: first.start,
            end: first.end,
          ),
        );
        if (matches.length >= _kMaxTotalSearchMatches) return matches;
      }
    }
  }
  return matches;
}

int reanchorConversationSearchMatch(
  List<ConversationSearchMatch> matches,
  String? previousIdentity,
  int fallbackIndex,
) {
  if (matches.isEmpty) return -1;
  if (previousIdentity != null) {
    final found = matches.indexWhere((m) => m.identity == previousIdentity);
    if (found >= 0) return found;
  }
  return fallbackIndex.clamp(0, matches.length - 1);
}

class ConversationSearchCloseResult {
  final ConversationSearchMatch? activeMatch;
  const ConversationSearchCloseResult(this.activeMatch);
}

/// 会话内搜索控制链。滚动与可见性定位由页面通过 onLocate/onAnchorMigrate
/// 完成；本类不 import 会话页，也不持有 ScrollController。
class ConversationSearchController {
  ConversationSearchController({
    required ConversationState? Function() stateProvider,
    required List<ChatItem> Function(ConversationState state) itemsProvider,
    required Future<bool> Function() loadOlder,
    required bool Function() isAlive,
    required void Function() onNotify,
    required Future<void> Function(ConversationSearchMatch match) onLocate,
    required void Function(String previousAnchor, String currentAnchor)
    onAnchorMigrate,
  }) : _stateProvider = stateProvider,
       _itemsProvider = itemsProvider,
       _loadOlder = loadOlder,
       _isAlive = isAlive,
       _onNotify = onNotify,
       _onLocate = onLocate,
       _onAnchorMigrate = onAnchorMigrate;

  final ConversationState? Function() _stateProvider;
  final List<ChatItem> Function(ConversationState state) _itemsProvider;
  final Future<bool> Function() _loadOlder;
  final bool Function() _isAlive;
  final void Function() _onNotify;
  final Future<void> Function(ConversationSearchMatch match) _onLocate;
  final void Function(String previousAnchor, String currentAnchor)
  _onAnchorMigrate;

  final controller = TextEditingController();
  final focusNode = FocusNode();
  bool isOpen = false;
  bool loading = false;
  bool truncated = false;
  bool stalled = false;
  bool useRegex = false;
  bool includeReasoning = false;
  int rowLimit = conversationSearchRowLimit;
  String? regexError;
  String? error;
  List<ConversationSearchMatch> matches = const [];
  int activeIndex = -1;
  int navigationId = 0;
  String? locatedIdentity;
  String _appliedQuery = '';
  RegExp? _compiledRegex;
  bool _historyPumping = false;
  int _pumpGeneration = 0;
  bool _disposed = false;

  String get query => controller.text;
  String get appliedQuery => _appliedQuery;
  RegExp? get compiledRegex => _compiledRegex;
  ConversationSearchMatch? get activeMatch =>
      activeIndex >= 0 && activeIndex < matches.length
      ? matches[activeIndex]
      : null;

  void open() {
    if (_disposed || _stateProvider() == null) return;
    _pumpGeneration++;
    isOpen = true;
    error = null;
    rowLimit = conversationSearchRowLimit;
    refresh(reset: true);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
    unawaited(pumpHistory());
  }

  ConversationSearchCloseResult close() {
    navigationId++;
    _pumpGeneration++;
    focusNode.unfocus();
    final result = ConversationSearchCloseResult(activeMatch);
    isOpen = false;
    loading = false;
    truncated = false;
    stalled = false;
    useRegex = false;
    includeReasoning = false;
    rowLimit = conversationSearchRowLimit;
    regexError = null;
    error = null;
    matches = const [];
    activeIndex = -1;
    locatedIdentity = null;
    _appliedQuery = '';
    _compiledRegex = null;
    controller.clear();
    _onNotify();
    return result;
  }

  void toggleRegex() {
    if (_disposed || !isOpen) return;
    useRegex = !useRegex;
    navigationId++;
    locatedIdentity = null;
    error = null;
    stalled = false;
    refresh(reset: true);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
    unawaited(pumpHistory());
  }

  void toggleIncludeReasoning() {
    if (_disposed || !isOpen) return;
    includeReasoning = !includeReasoning;
    navigationId++;
    locatedIdentity = null;
    refresh(reset: true);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
  }

  /// 突破 1200 行初始补拉上限：用户主动要求继续往前拉取下一批 1200 行。
  void loadMoreHistory() {
    if (_disposed || !isOpen || loading) return;
    rowLimit += conversationSearchRowLimit;
    truncated = false;
    stalled = false;
    error = null;
    _onNotify();
    unawaited(pumpHistory());
  }

  void refresh({bool reset = false}) {
    final state = _stateProvider();
    if (state == null || _disposed) return;
    final previous = activeMatch?.identity;
    final previousAnchor = activeMatch?.anchorKey;
    final trimmed = controller.text.trim();
    _appliedQuery = controller.text;
    if (useRegex && trimmed.isNotEmpty) {
      if (_compiledRegex != null &&
          _compiledRegex!.pattern == trimmed &&
          regexError == null) {
        // 复用同模式预编译 RegExp（避免流式刷新或列表 rebuild 重复编译）。
      } else {
        final compiled = compileSearchRegex(trimmed);
        _compiledRegex = compiled.regex;
        regexError = compiled.error;
      }
    } else {
      _compiledRegex = null;
      regexError = null;
    }
    matches = regexError != null
        ? const []
        : buildConversationSearchMatches(
            _itemsProvider(state),
            controller.text,
            useRegex: useRegex,
            includeReasoning: includeReasoning,
            compiledRegex: _compiledRegex,
          );
    activeIndex = reset
        ? (matches.isEmpty ? -1 : 0)
        : reanchorConversationSearchMatch(
            matches,
            previous,
            activeIndex < 0 ? 0 : activeIndex,
          );
    truncated = trimmed.isNotEmpty &&
        regexError == null &&
        state.rows.length >= rowLimit &&
        state.canLoadOlder;
    final currentAnchor = activeMatch?.anchorKey;
    if (previousAnchor != null &&
        currentAnchor != null &&
        previousAnchor != currentAnchor) {
      _onAnchorMigrate(previousAnchor, currentAnchor);
    }
  }

  void change(String _) {
    navigationId++;
    locatedIdentity = null;
    error = null;
    stalled = false;
    refresh(reset: true);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
    unawaited(pumpHistory());
  }

  void step(int direction) {
    if (matches.isEmpty) return;
    final count = matches.length;
    activeIndex = direction > 0
        ? (activeIndex + 1) % count
        : (activeIndex <= 0 ? count - 1 : activeIndex - 1);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
  }

  void cancelNavigation() {
    navigationId++;
  }

  void retry() {
    error = null;
    unawaited(pumpHistory());
  }

  /// 定位实际开始（页面守卫通过后）才标记已定位——先标记会让
  /// pumpHistory 的补定位条件（locatedIdentity==null）永久失效
  ///（独立复核低 1：列表未挂载时首个命中不再自动滚入）。
  void markLocated(ConversationSearchMatch match) {
    locatedIdentity = match.identity;
  }

  void _locate(ConversationSearchMatch match) {
    unawaited(_onLocate(match));
  }

  Future<void> pumpHistory() async {
    if (_historyPumping || !isOpen || _disposed) return;
    final query = controller.text.trim();
    if (query.isEmpty) return;
    if (useRegex && compileSearchRegex(query).error != null) return;
    final gen = _pumpGeneration;
    final targetLimit = rowLimit;
    final initial = _stateProvider();
    if (initial == null ||
        !initial.canLoadOlder ||
        initial.rows.length >= targetLimit ||
        initial.phase == 'running' ||
        initial.phase == 'prewarming') {
      return;
    }
    _historyPumping = true;
    if (_isAlive()) {
      loading = true;
      error = null;
      _onNotify();
    }
    try {
      while (_isAlive() &&
          isOpen &&
          _pumpGeneration == gen &&
          regexError == null &&
          controller.text.trim() == query) {
        final state = _stateProvider();
        if (state == null ||
            !state.canLoadOlder ||
            state.rows.length >= rowLimit ||
            state.phase == 'running' ||
            state.phase == 'prewarming') {
          break;
        }
        final progressed = await _loadOlder();
        if (!_isAlive() ||
            _pumpGeneration != gen ||
            controller.text.trim() != query) {
          break;
        }
        refresh();
        if (regexError != null) break;
        if (!progressed) {
          if (_stateProvider()?.canLoadOlder == true) stalled = true;
          break;
        }
        final active = activeMatch;
        if (active != null && locatedIdentity == null) _locate(active);
      }
    } catch (caught) {
      if (_isAlive() &&
          isOpen &&
          _pumpGeneration == gen &&
          controller.text.trim() == query) {
        error = '$caught';
      }
    } finally {
      _historyPumping = false;
      if (_isAlive()) {
        if (_pumpGeneration == gen) {
          loading = false;
          refresh();
          _onNotify();
          if (isOpen && activeMatch != null && locatedIdentity == null) {
            _locate(activeMatch!);
          }
          if (isOpen &&
              (controller.text.trim() != query || rowLimit > targetLimit)) {
            unawaited(pumpHistory());
          }
        } else if (isOpen) {
          // 关闭后立即重开的新代际等待旧协程收尾后自动补拉。
          unawaited(pumpHistory());
        }
      }
    }
  }

  String? get partialNotice {
    if (!isOpen || loading || truncated || error != null || regexError != null) {
      return null;
    }
    final state = _stateProvider();
    if (state?.canLoadOlder != true) return null;
    if (state!.phase == 'running' || state.phase == 'prewarming') {
      return tr('当前仅搜索已加载内容，运行结束后自动补查更早消息');
    }
    if (stalled) return tr('更早历史暂时不可用，当前仅显示已加载范围');
    return null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    navigationId++;
    controller.dispose();
    focusNode.dispose();
  }
}

class ConversationSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final List<ConversationSearchMatch> matches;
  final int activeIndex;
  final bool loading;
  final bool truncated;
  final int rowLimit;
  final bool useRegex;
  final bool includeReasoning;
  final String? regexError;
  final String? error;
  final String? partialNotice;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;
  final VoidCallback onRetry;
  final VoidCallback? onToggleRegex;
  final VoidCallback? onToggleIncludeReasoning;
  final VoidCallback? onLoadMore;

  const ConversationSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.matches,
    required this.activeIndex,
    required this.loading,
    required this.truncated,
    this.rowLimit = conversationSearchRowLimit,
    this.useRegex = false,
    this.includeReasoning = false,
    this.regexError,
    required this.error,
    this.partialNotice,
    required this.onChanged,
    this.onSubmitted,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
    required this.onRetry,
    this.onToggleRegex,
    this.onToggleIncludeReasoning,
    this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    final hasQuery = query.trim().isNotEmpty;
    final active = activeIndex >= 0 && activeIndex < matches.length
        ? matches[activeIndex]
        : null;
    final kindLabel = switch (active?.kind) {
      ConversationSearchKind.user => '提问',
      ConversationSearchKind.assistant => 'AI 回复',
      ConversationSearchKind.tool => '工具',
      ConversationSearchKind.reasoning => '思考',
      null => '',
    };
    return Material(
      key: const ValueKey('conversation-search-bar'),
      color: context.colors.header,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.colors.border)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('conversation-search-input'),
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    onChanged: onChanged,
                    onSubmitted: (_) => (onSubmitted ?? onNext)(),
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: AppType.mobileInputSafe),
                    decoration: InputDecoration(
                      hintText: tr('搜索消息和工具'),
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                if (hasQuery)
                  Text(
                    activeIndex < 0
                        ? '0/${matches.length}'
                        : '${activeIndex + 1}/${matches.length}',
                    key: const ValueKey('conversation-search-count'),
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                // 审美门建议②：可见图形放大（arrow 图形稀疏视觉
                // 偏小——28/24 进 40dp 可见档；隐性触控面 48 不变）。
                IconButton(
                  key: const ValueKey('conversation-search-previous'),
                  onPressed: matches.isEmpty ? null : onPrevious,
                  icon: const Icon(Icons.keyboard_arrow_up, size: 28),
                  tooltip: tr('上一个匹配项'),
                ),
                IconButton(
                  key: const ValueKey('conversation-search-next'),
                  onPressed: matches.isEmpty ? null : onNext,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 28),
                  tooltip: tr('下一个匹配项'),
                ),
                IconButton(
                  key: const ValueKey('conversation-search-close'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 24),
                  tooltip: tr('关闭'),
                ),
              ],
            ),
            if (onToggleRegex != null || onToggleIncludeReasoning != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (onToggleRegex != null)
                        _SearchOptionChip(
                          key: const ValueKey('conversation-search-regex'),
                          label: '正则',
                          selected: useRegex,
                          onTap: onToggleRegex!,
                        ),
                      if (onToggleIncludeReasoning != null)
                        _SearchOptionChip(
                          key: const ValueKey('conversation-search-reasoning'),
                          label: '含思考',
                          selected: includeReasoning,
                          onTap: onToggleIncludeReasoning!,
                        ),
                    ],
                  ),
                ),
              ),
            if (active != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kindLabel,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontWeight: FontWeight.w600,
                        // 验收#11（I）：accent 深色档=近黑深藏青
                        // （0xFF001D3D）叠深色 header 上几乎不可见——
                        // 改品牌蓝（浅 #134CFF/深 #4099FF，两档可读）。
                        color: context.colors.brandAccent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        active.snippet,
                        key: const ValueKey('conversation-search-snippet'),
                        translate: false,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (loading ||
                truncated ||
                regexError != null ||
                error != null ||
                partialNotice != null ||
                (hasQuery && matches.isEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: regexError != null
                      ? Text(
                          regexError == '正则表达式过于复杂'
                              ? '正则表达式过于复杂'
                              : '正则表达式无效',
                          key: const ValueKey('conversation-search-regex-error'),
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.destructive,
                          ),
                        )
                      : error != null
                      ? TextButton.icon(
                          key: const ValueKey('conversation-search-retry'),
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('历史加载失败，点按重试'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 48),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                        )
                      : truncated && !loading
                      ? Wrap(
                          spacing: 8,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '已搜索最近 $rowLimit 行，更早内容未纳入',
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: context.colors.foregroundSubtle,
                              ),
                            ),
                            if (onLoadMore != null)
                              TextButton(
                                key: const ValueKey(
                                  'conversation-search-load-more',
                                ),
                                onPressed: onLoadMore,
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  minimumSize: const Size(48, 32),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  foregroundColor: context.colors.brandAccent,
                                ),
                                child: const Text(
                                  '继续往前搜',
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        )
                      : Text(
                          loading
                              ? '正在加载更早消息…'
                              : partialNotice ??
                                    (!useRegex &&
                                            splitSearchTerms(query).length > 1
                                        ? '没有匹配结果：多个词需同时出现在同一条消息'
                                        : '没有匹配结果'),
                          key: const ValueKey(
                            'conversation-search-empty-reason',
                          ),
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchOptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SearchOptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // 1.0.9 真机验收②（入口不明显）：旧态=11dp 灰字+1.17:1 极淡描边+
    // 透明底，视觉子代理判定为全面板最低对比行、读作静态标签。升档：
    // 13dp+未选中淡实底+500 字重，可点感对齐按钮。
    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          backgroundColor: selected
              ? c.brandAccent.withValues(alpha: AppAlpha.light)
              : c.foreground.withValues(alpha: AppAlpha.faint),
          foregroundColor: selected ? c.brandAccent : c.foreground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            side: BorderSide(
              color: selected ? c.brandAccent : c.border,
              width: 1,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppType.uiCaption,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
