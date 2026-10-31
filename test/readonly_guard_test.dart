import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「绝对只读 / 零静默请求 / 零硬编码凭据」的自动化守卫。
///
/// 这个文件不测业务逻辑，它扫描源码本身，把三条红线变成可在 CI 里失败的断言：
///
///  1. **不许写网页**：lib 与 assets 里不得出现 click / dispatchEvent /
///     innerHTML 或 value 赋值 / setAttribute 等 DOM 写操作；
///  2. **不许后台偷跑请求**：网络层（core/network、data/services）不得出现
///     定时器，任何请求只能由用户点击触发；
///  3. **不许内置真 Key**：源码里不得出现 `sk-` 开头的长串密钥。
///
/// 一旦将来有人加了「自动提交」「自动刷新」之类的代码，这里会立刻红。
void main() {
  /// 递归收集目录下指定后缀的文件（跳过 build / node_modules）
  List<File> collect(String root, List<String> extensions) {
    final dir = Directory(root);
    if (!dir.existsSync()) return <File>[];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) {
          final p = f.path.replaceAll('\\', '/');
          if (p.contains('/node_modules/') || p.contains('/build/')) {
            return false;
          }
          return extensions.any(p.endsWith);
        })
        .toList();
  }

  /// 返回命中的 `路径:行号 → 内容`
  ///
  /// 带 `readonly-audit-ok` 标记的行会被跳过——这是唯一的人工豁免通道，
  /// 且标记数量本身也受下面的用例约束（不许到处撒）。
  List<String> scan(List<File> files, List<RegExp> patterns) {
    final hits = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('readonly-audit-ok')) continue;
        for (final pattern in patterns) {
          if (pattern.hasMatch(lines[i])) {
            hits.add('${file.path}:${i + 1} → ${lines[i].trim()}');
            break;
          }
        }
      }
    }
    return hits;
  }

  group('红线一：绝对只读，不修改网页', () {
    /// DOM 写操作的全家桶：点一下、派个事件、改内容、改值、改属性
    final forbidden = <RegExp>[
      RegExp(r'\.click\s*\('),
      RegExp(r'\.dispatchEvent\s*\('),
      RegExp(r'innerHTML\s*=[^=]'),
      RegExp(r'outerHTML\s*=[^=]'),
      RegExp(r'insertAdjacentHTML'),
      RegExp(r'\.insertAdjacentText'),
      RegExp(r'\.value\s*=[^=]'),
      RegExp(r'\.checked\s*=[^=]'),
      RegExp(r'\.setAttribute\s*\('),
      RegExp(r'\.removeAttribute\s*\('),
      RegExp(r'\.appendChild\s*\('),
      RegExp(r'\.removeChild\s*\('),
      RegExp(r'\.insertBefore\s*\('),
      RegExp(r'\.replaceChild\s*\('),
      RegExp(r'\.removeProperty\s*\('),
      RegExp(r'\.style\.[a-zA-Z]+\s*=[^=]'),
      RegExp(r'document\.write'),
      RegExp(r'document\.execCommand'),
      RegExp(r'\.submit\s*\('),
    ];

    test('lib/ 下没有任何 DOM 写操作', () {
      final hits = scan(collect('lib', <String>['.dart']), forbidden);
      expect(hits, isEmpty, reason: '发现疑似写网页的代码：\n${hits.join('\n')}');
    });

    test('assets/ 下的注入脚本没有任何 DOM 写操作', () {
      final hits = scan(collect('assets', <String>['.js']), forbidden);
      expect(hits, isEmpty, reason: '发现疑似写网页的脚本：\n${hits.join('\n')}');
    });

    test('提取脚本只用 querySelector 读文字（抽样确认）', () {
      final js = File('assets/js/extractor.js').readAsStringSync();
      expect(js.contains('querySelectorAll'), isTrue);
      expect(js.contains('textContent') || js.contains('innerText'), isTrue);
      // 唯一的 removeChild 必须作用在脱离文档的副本上
      if (js.contains('removeChild')) {
        expect(
          js.contains('cloneNode(true)'),
          isTrue,
          reason: 'removeChild 若不在 cloneNode 副本上，会改到真实 DOM',
        );
      }
    });

    test('只读豁免标记全仓库至多 1 处，且只允许在提取脚本里', () {
      final hits = <String>[];
      final files = <File>[
        ...collect('lib', <String>['.dart']),
        ...collect('assets', <String>['.js']),
      ];
      for (final file in files) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('readonly-audit-ok')) {
            hits.add('${file.path}:${i + 1}');
          }
        }
      }
      expect(
        hits.length,
        lessThanOrEqualTo(1),
        reason: '豁免标记被到处使用，等于没守卫：${hits.join(', ')}',
      );
      if (hits.isNotEmpty) {
        expect(hits.single, contains('extractor.js'));
      }
    });
  });

  group('红线二：所有学习通请求都由用户点击触发', () {
    test('网络层与数据层没有任何定时器', () {
      final files = <File>[
        ...collect('lib/core/network', <String>['.dart']),
        ...collect('lib/data/services', <String>['.dart']),
      ];
      final hits = scan(files, <RegExp>[
        RegExp(r'Timer\.periodic'),
        RegExp(r'Timer\s*\('),
        RegExp(r'Future\.delayed'),
      ]);
      expect(hits, isEmpty, reason: '网络层出现定时器，可能变成静默轮询：\n${hits.join('\n')}');
    });

    test('启动页不联网（只做本地 Cookie 判断）', () {
      final src = File('lib/ui/pages/splash_gate_page.dart').readAsStringSync();
      expect(src.contains('package:dio'), isFalse);
      expect(src.contains('DioClient'), isFalse);
      expect(src.contains('hasValidSession'), isFalse);
      expect(src.contains('hasLocalSession'), isTrue);
    });

    test('登录态校验不存在「请求服务器」的实现', () {
      final src = File('lib/core/network/cookie_sync_helper.dart').readAsStringSync();
      expect(src.contains('i.chaoxing.com/base'), isFalse);
      expect(src.contains('_verifyWithServer'), isFalse);
    });
  });

  group('红线三：仓库里没有真凭据', () {
    test('源码与脚本里没有 sk- 开头的长串密钥', () {
      final files = <File>[
        ...collect('lib', <String>['.dart']),
        ...collect('assets', <String>['.js']),
      ];
      final hits = scan(files, <RegExp>[RegExp(r'sk-[A-Za-z0-9_\-]{20,}')]);
      expect(hits, isEmpty, reason: '疑似硬编码密钥：\n${hits.join('\n')}');
    });

    test('没有把 Cookie / 签名文件放进仓库', () {
      for (final path in <String>[
        'key.properties',
        'android/key.properties',
        '.env',
      ]) {
        expect(File(path).existsSync(), isFalse, reason: '$path 不该出现在仓库里');
      }
      final jks = collect('.', <String>['.jks', '.keystore']);
      expect(jks, isEmpty, reason: '签名文件不该入库');
    });
  });
}
