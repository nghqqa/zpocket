import 'package:flutter_test/flutter_test.dart';

import 'package:zpocket/ui/workspace_path_actions.dart';

void main() {
  group('looksLikeWorkspacePath', () {
    test('带分隔符的路径识别', () {
      expect(looksLikeWorkspacePath('tools/release.py'), isTrue);
      expect(looksLikeWorkspacePath('app/lib/ui/file_save.dart'), isTrue);
      expect(looksLikeWorkspacePath(r'E:\zcode-my\zpocket\tools\release.py'),
          isTrue);
      expect(looksLikeWorkspacePath('/home/u/report.pdf'), isTrue);
    });

    test('纯文件名须扩展名在白名单', () {
      expect(looksLikeWorkspacePath('app-arm64-v8a-release.apk'), isTrue,
          reason: 'apk 在白名单（用户实际点按场景）');
      expect(looksLikeWorkspacePath('release.py'), isTrue);
      expect(looksLikeWorkspacePath('README'), isFalse, reason: '无扩展名');
      expect(looksLikeWorkspacePath('1.0.5'), isFalse, reason: '版本号');
    });

    test('明确排除：URL/空白/纯数字/过长', () {
      expect(looksLikeWorkspacePath('https://nghqqa.cn/x.apk'), isFalse,
          reason: '网络链接走链接分支');
      expect(looksLikeWorkspacePath('npm run dev'), isFalse, reason: '含空白');
      expect(looksLikeWorkspacePath('--dart-define=x'), isFalse);
      expect(looksLikeWorkspacePath('a' * 300), isFalse);
    });
  });

  group('pathCandidates', () {
    const ws = 'E:/zcode-my/zpocket';
    test('命中 workspace 前缀 → 相对形态优先，原样兜底', () {
      final out = pathCandidates(r'E:\zcode-my\zpocket\tools\release.py', ws);
      expect(out.first, 'tools/release.py');
      expect(out.last, 'E:/zcode-my/zpocket/tools/release.py');
    });

    test('大小写不敏感匹配 workspace 前缀', () {
      final out = pathCandidates('e:/ZCode-My/Zpocket/README.md', ws);
      expect(out.first, 'README.md');
    });

    test('相对路径与外部绝对路径原样保留', () {
      expect(pathCandidates('tools/release.py', ws),
          ['tools/release.py']);
      expect(pathCandidates('C:/Windows/hosts', ws), ['C:/Windows/hosts']);
      expect(pathCandidates('x.apk', null), ['x.apk'],
          reason: '未连接 workspace=无前缀可剥');
    });
  });

  group('looksLikeTextFile', () {
    test('白名单文本扩展名', () {
      expect(looksLikeTextFile('a.txt'), isTrue);
      expect(looksLikeTextFile('b.dart'), isTrue);
      expect(looksLikeTextFile('c.pdf'), isFalse, reason: '二进制档不给预览');
      expect(looksLikeTextFile('d.apk'), isFalse);
      expect(looksLikeTextFile('noext'), isFalse);
    });
  });
}
