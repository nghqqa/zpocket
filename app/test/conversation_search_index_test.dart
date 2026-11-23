import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/ui/conversation_message_cells.dart';
import 'package:zpocket/ui/conversation_search.dart';
import 'package:zpocket/ui/turn_model.dart';

List<Map<String, dynamic>> _rows() => [
  {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
  {'rowId': 2, 'kind': 'userInput', 'text': 'Needle needle'},
  {'rowId': 3, 'kind': 'reasoning', 'text': 'needle must not be indexed'},
  {
    'rowId': 4,
    'kind': 'toolCall',
    'toolName': 'Bash',
    'status': 'success',
    'input': {'command': 'echo needle'},
    'output': {'text': 'needle in output'},
  },
  {'rowId': 5, 'kind': 'assistantText', 'text': 'Alpha NEEDLE'},
];

void main() {
  test('提问/回复/工具输入输出计数，思考不搜，匹配保持原文与稳定锚点', () {
    final matches = buildConversationSearchMatches(
      buildChatItems(_rows()),
      'needle',
    );
    expect(matches, hasLength(5));
    expect(
      matches.where((m) => m.kind == ConversationSearchKind.user),
      hasLength(2),
    );
    expect(
      matches.where((m) => m.kind == ConversationSearchKind.tool),
      hasLength(2),
    );
    expect(
      matches.where((m) => m.kind == ConversationSearchKind.assistant),
      hasLength(1),
    );
    expect(matches.last.sourceText, 'Alpha NEEDLE');
    expect(matches.last.anchorKey, 'turn-h1');
    expect(matches.map((m) => m.identity).toSet(), hasLength(5));
    expect(matches.first.snippet, contains('Needle needle'));
  });

  test('字面匹配非重叠，空查询不索引，大小写不敏感', () {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': 'AaAa'},
    ];
    final items = buildChatItems(rows);
    expect(buildConversationSearchMatches(items, 'aa'), hasLength(2));
    expect(buildConversationSearchMatches(items, '  '), isEmpty);
    expect(buildConversationSearchMatches(items, 'a.a'), isEmpty);
  });

  // toLowerCase 对 İ（U+0130）扩长（1 码元→
  // 'i'+U+0307 两码元），折叠串下标漂移——命中 start/end 必须落在原串
  // 坐标系（snippet 切 sourceText 不越界不错位）。
  test('İ（U+0130）折叠扩长：命中区间与 snippet 落在原串坐标系', () {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': 'İabc needle'},
    ];
    final items = buildChatItems(rows);
    final matches = buildConversationSearchMatches(items, 'needle');
    expect(matches, hasLength(1));
    final m = matches.single;
    expect(m.sourceText.substring(m.start, m.end), 'needle',
        reason: '命中区间切原文恰为关键词');
    expect(m.snippet, contains('İabc'),
        reason: 'snippet 上下文不错位（İ 保持原文）');

    // 漂移点之后命中的极端尾沿：substring/snippet 均不越界。
    final tail = buildConversationSearchMatches(
      buildChatItems([
        {'rowId': 1, 'kind': 'userInput', 'text': 'İneedle'},
      ]),
      'needle',
    );
    expect(tail, hasLength(1));
    expect(tail.single.start, 1, reason: 'İ 折叠为单码元 i，原串下标=1');
    expect(tail.single.sourceText.substring(tail.single.start, tail.single.end),
        'needle');
  });

  test('历史前插后按行与出现序号重锚当前匹配', () {
    final oldMatches = buildConversationSearchMatches(
      buildChatItems(_rows()),
      'needle',
    );
    final previous = oldMatches.last.identity;
    final older = [
      {'rowId': 90, 'kind': 'userInput', 'text': 'older needle'},
      ..._rows(),
    ];
    final matches = buildConversationSearchMatches(
      buildChatItems(older),
      'needle',
    );
    final index = reanchorConversationSearchMatch(matches, previous, 0);
    expect(matches[index].rowId, 5);
    expect(matches[index].kind, ConversationSearchKind.assistant);
  });

  test('工具错误与 bash display 输出可搜，隐藏 outputPreview 不冒充完成输出', () {
    final rows = [
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'error',
        'error': {'message': 'permission needle'},
        'outputPreview': {'fullText': 'hidden needle'},
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'success',
        'output': {
          'display': {'kind': 'bash_output', 'output': 'terminal needle'},
        },
      },
    ];
    final matches = buildConversationSearchMatches(
      buildChatItems(rows),
      'needle',
    );
    expect(matches.map((m) => m.rowId), containsAll([2, 3]));
    expect(
      matches.where((m) => m.sourceText.contains('hidden needle')),
      isEmpty,
    );
  });

  test('空格多词 AND：仅命中同时包含全部词的消息且不限词序', () {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': 'alpha only'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'beta only'},
      {'rowId': 3, 'kind': 'userInput', 'text': 'beta comes before ALPHA'},
      {
        'rowId': 4,
        'kind': 'assistantText',
        'text': 'alpha middle alpha and beta',
      },
    ];
    final items = buildChatItems(rows);

    final forward = buildConversationSearchMatches(items, 'alpha beta');
    expect(forward.map((m) => m.rowId).toSet(), {3, 4});
    // 离散多词 AND 每条命中消息计 1 次定位（高亮层覆盖全词）
    expect(forward.where((m) => m.rowId == 3), hasLength(1));
    expect(forward.where((m) => m.rowId == 4), hasLength(1));

    final reversed = buildConversationSearchMatches(items, 'beta alpha');
    expect(reversed.map((m) => m.rowId).toSet(), {3, 4});
  });

  test('正则模式：大小写不敏感、非法正则返回空、零宽正则不死循环且跳过零宽命中', () {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': 'HTTP ERR   404 not found'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'err404 without'},
      {'rowId': 3, 'kind': 'userInput', 'text': 'baac'},
    ];
    final items = buildChatItems(rows);

    final regexMatches = buildConversationSearchMatches(
      items,
      r'err\s+\d+',
      useRegex: true,
    );
    expect(regexMatches, hasLength(1));
    expect(regexMatches.single.rowId, 1);
    expect(
      regexMatches.single.sourceText.substring(
        regexMatches.single.start,
        regexMatches.single.end,
      ),
      'ERR   404',
    );

    expect(
      buildConversationSearchMatches(items, '[unclosed', useRegex: true),
      isEmpty,
    );
    expect(
      buildConversationSearchMatches(items, '^', useRegex: true),
      isEmpty,
    );

    final starMatches = buildConversationSearchMatches(
      items,
      'a*',
      useRegex: true,
    );
    expect(starMatches, hasLength(1));
    expect(starMatches.single.rowId, 3);
    expect(starMatches.single.start, 1);
    expect(starMatches.single.end, 3);
  });

  test('includeReasoning=true 索引思考行并返回 reasoning 类型，false 时跳过', () {
    final items = buildChatItems(_rows());

    final withoutReasoning = buildConversationSearchMatches(
      items,
      'needle',
      includeReasoning: false,
    );
    expect(withoutReasoning, hasLength(5));
    expect(
      withoutReasoning.where(
        (m) => m.kind == ConversationSearchKind.reasoning,
      ),
      isEmpty,
    );

    final withReasoning = buildConversationSearchMatches(
      items,
      'needle',
      includeReasoning: true,
    );
    expect(withReasoning, hasLength(6));
    final reasoningMatches = withReasoning
        .where((m) => m.kind == ConversationSearchKind.reasoning)
        .toList();
    expect(reasoningMatches, hasLength(1));
    expect(reasoningMatches.single.rowId, 3);
    expect(reasoningMatches.single.anchorKey, 'turn-h1');
    expect(reasoningMatches.single.snippet, contains('needle must not be indexed'));
  });

  test('findSearchMatchRanges 与 buildSearchHighlightSpans 覆盖多词 AND 合并与正则高亮', () {
    // 多词 AND：不限词序、缺词空、重叠区间合并
    final multiRanges = findSearchMatchRanges(
      'Beta then Alpha',
      'alpha beta',
    );
    expect(multiRanges, [(start: 0, end: 4), (start: 10, end: 15)]);

    final mergedRanges = findSearchMatchRanges('abcdef', 'abc bcd');
    expect(mergedRanges, [(start: 0, end: 4)]);

    expect(findSearchMatchRanges('alpha only', 'alpha beta'), isEmpty);

    // 正则与零宽保护
    final regexRanges = findSearchMatchRanges(
      'ERR 404 and err\t500',
      r'err\s+\d+',
      useRegex: true,
    );
    expect(regexRanges, [(start: 0, end: 7), (start: 12, end: 19)]);
    expect(findSearchMatchRanges('ba', '^', useRegex: true), isEmpty);
    expect(
      findSearchMatchRanges('ba', 'a*', useRegex: true),
      [(start: 1, end: 2)],
    );

    const base = TextStyle(fontSize: 14);
    const hit = TextStyle(fontSize: 14, fontWeight: FontWeight.bold);

    final multiSpans = buildSearchHighlightSpans(
      'Beta then Alpha!',
      'alpha beta',
      base: base,
      hit: hit,
    ).cast<TextSpan>();
    expect(multiSpans.map((s) => s.text).toList(), [
      'Beta',
      ' then ',
      'Alpha',
      '!',
    ]);
    expect(multiSpans.map((s) => s.style).toList(), [hit, base, hit, base]);

    final missSpans = buildSearchHighlightSpans(
      'Beta only',
      'alpha beta',
      base: base,
      hit: hit,
    ).cast<TextSpan>();
    expect(missSpans, hasLength(1));
    expect(missSpans.single.text, 'Beta only');
    expect(missSpans.single.style, base);

    final regexSpans = buildSearchHighlightSpans(
      'code ERR 404!',
      r'err\s+\d+',
      base: base,
      hit: hit,
      useRegex: true,
    ).cast<TextSpan>();
    expect(regexSpans.map((s) => s.text).toList(), [
      'code ',
      'ERR 404',
      '!',
    ]);
    expect(regexSpans.map((s) => s.style).toList(), [base, hit, base]);
  });
}
