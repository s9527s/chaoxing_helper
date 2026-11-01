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
  /// 纯注释行（`//`、`///`、块注释的 `*`）也跳过：守卫要拦的是可执行代码，
  /// 而注释里恰恰会写「这里刻意不使用 xxx」这类说明。
  List<String> scan(List<File> files, List<RegExp> patterns) {
    final hits = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('readonly-audit-ok')) continue;
        final trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//') ||
            trimmed.startsWith('*') ||
            trimmed.startsWith('/*')) {
          continue;
        }
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
    /// DOM 写操作的全家桶：点一下、派个事件、改内容、改值、改属性、改地址
    final forbidden = <RegExp>[
      RegExp(r'\.click\s*\('),
      RegExp(r'\.dispatchEvent\s*\('),
      RegExp(r'innerHTML\s*=[^=]'),
      RegExp(r'outerHTML\s*=[^=]'),
      RegExp(r'insertAdjacentHTML'),
      RegExp(r'\.insertAdjacentText'),
      RegExp(r'\.textContent\s*=[^=]'),
      RegExp(r'\.innerText\s*=[^=]'),
      RegExp(r'\.value\s*=[^=]'),
      RegExp(r'\.checked\s*=[^=]'),
      RegExp(r'\.href\s*=[^=]'),
      RegExp(r'\.src\s*=[^=]'),
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

    /// 只在 JS 里有意义、Dart 里属于正常 API 的写法（如 `List.remove`），
    /// 因此单独一组，仅用于扫注入脚本。
    final forbiddenInJsOnly = <RegExp>[
      RegExp(r'\.remove\s*\('),
      RegExp(r'\.removeAttributeNode\s*\('),
      RegExp(r'\.delete\s+[A-Za-z_$]'),
    ];

    test('lib/ 下没有任何 DOM 写操作', () {
      final hits = scan(collect('lib', <String>['.dart']), forbidden);
      expect(hits, isEmpty, reason: '发现疑似写网页的代码：\n${hits.join('\n')}');
    });

    test('assets/ 下的注入脚本没有任何 DOM 写操作', () {
      final hits = scan(collect('assets', <String>['.js']), <RegExp>[
        ...forbidden,
        ...forbiddenInJsOnly,
      ]);
      expect(hits, isEmpty, reason: '发现疑似写网页的脚本：\n${hits.join('\n')}');
    });

    test('提取脚本只用 querySelector 读文字（抽样确认）', () {
      final js = File('assets/js/extractor.js').readAsStringSync();
      expect(js.contains('querySelectorAll'), isTrue);
      expect(js.contains('innerText'), isTrue);
      // 文本读取改成纯遍历：不再 clone、不再 removeChild，页面零改动
      expect(js.contains('cloneNode'), isFalse);
      expect(js.contains('removeChild'), isFalse);
      // 只允许主框架往 Flutter 抛数据
      expect(js.contains('window.top !== window.self'), isTrue);
    });

    test('全仓库没有任何只读豁免标记（当前为 0 处）', () {
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
        hits,
        isEmpty,
        reason: '出现人工豁免就意味着守卫被绕过：${hits.join(', ')}',
      );
    });
  });

  group('红线一之二：只交字段，不交页面结构', () {
    test('lib/ 与 assets/ 里完全不出现 outerHTML / innerHTML', () {
      final hits = scan(<File>[
        ...collect('lib', <String>['.dart']),
        ...collect('assets', <String>['.js']),
      ], <RegExp>[
        RegExp(r'outerHTML'),
        RegExp(r'innerHTML'),
      ]);
      expect(
        hits,
        isEmpty,
        reason: '页面结构不得整段交给 Dart（连长度统计都不允许）：\n${hits.join('\n')}',
      );
    });

    test('注入脚本不读 Cookie / 存储 / 跨帧文档', () {
      final hits = scan(collect('assets', <String>['.js']), <RegExp>[
        RegExp(r'document\.cookie'),
        RegExp(r'localStorage'),
        RegExp(r'sessionStorage'),
        RegExp(r'contentDocument'),
        RegExp(r'contentWindow'),
      ]);
      expect(hits, isEmpty, reason: '脚本越界读了不该读的东西：\n${hits.join('\n')}');
    });

    test('Dart 侧不再解析 HTML 字符串', () {
      final src =
          File('lib/data/services/scanner_service.dart').readAsStringSync();
      for (final banned in <String>[
        'package:html',
        'html_parser',
        'parseTasksFromHtml',
        'parseCourseListHtml',
        'outerHTML',
      ]) {
        expect(
          src.contains(banned),
          isFalse,
          reason: '扫描服务仍在处理 HTML：命中 $banned',
        );
      }
      // 只保留结构化入口
      expect(src.contains('parseTaskRows'), isTrue);
      expect(src.contains('parseCourseRows'), isTrue);
    });

    test('页面读取脚本只暴露 tasks / courses 两个方法', () {
      final js = File('assets/js/page_reader.js').readAsStringSync();
      expect(js.contains('window.__cxPageReader'), isTrue);
      expect(js.contains('tasks: function'), isTrue);
      expect(js.contains('courses: function'), isTrue);
      // 只读兜底：不能出现任何写操作
      expect(js.contains('.click('), isFalse);
      expect(js.contains('setAttribute'), isFalse);
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

    test('WebView 页面加载阶段不注入脚本、不采集 HTML', () {
      final src = File('lib/ui/pages/work_webview_page.dart').readAsStringSync();
      // frame 上报桥 / 文档启动即注入，都是「页面一加载就抓一份 HTML」的形态
      for (final banned in <String>[
        'onFrameHtml',
        'initialUserScripts',
        'AT_DOCUMENT_START',
        'UserScript(',
      ]) {
        expect(
          src.contains(banned),
          isFalse,
          reason: '页面加载阶段不得注入采集脚本，命中 $banned',
        );
      }
    });

    test('不再存在任何「刷新取数」服务', () {
      expect(
        File('lib/data/services/task_refresh_service.dart').existsSync(),
        isFalse,
        reason: '开源版不通过接口拉取学习通数据，刷新服务应已删除',
      );
      final hits = scan(collect('lib', <String>['.dart']), <RegExp>[
        RegExp(r'TaskRefreshService'),
        RegExp(r'refreshCourses'),
      ]);
      expect(hits, isEmpty, reason: '刷新链路残留：\n${hits.join('\n')}');
    });
  });

  group('附加：AI 服务只发文字，不下载页面资源', () {
    test('ai_solver_service 里没有任何图片/base64 处理', () {
      final src = File('lib/data/services/ai_solver_service.dart').readAsStringSync();
      // 旧实现会带 Cookie 去 GET 图片再 base64，属于「绝对只读」之外的多余出口
      for (final banned in <String>[
        'base64',
        'image_url',
        'stemImages',
        'ResponseType.bytes',
        'downloadImage',
      ]) {
        expect(
          src.contains(banned),
          isFalse,
          reason: 'ai_solver_service 里不该再出现 $banned',
        );
      }
    });

    test('lib 下不存在任何图片下载方法', () {
      final hits = scan(collect('lib', <String>['.dart']), <RegExp>[
        RegExp(r'[Dd]ownloadImage'),
        RegExp(r'base64Encode'),
        RegExp(r'image_url'),
      ]);
      expect(hits, isEmpty, reason: '仍存在图片/base64 相关代码：\n${hits.join('\n')}');
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
