import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/config/app_config.dart';
import '../../data/services/ai_solver_service.dart';
import '../../data/services/scanner_service.dart';
import '../widgets/solving_bottom_sheet.dart';

class WorkWebViewPage extends StatefulWidget {
  final String workTitle;
  final String workUrl;

  const WorkWebViewPage({
    super.key,
    required this.workTitle,
    required this.workUrl,
  });

  @override
  State<WorkWebViewPage> createState() => _WorkWebViewPageState();
}

class _WorkWebViewPageState extends State<WorkWebViewPage> {
  static const String _desktopUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 默认参与自动作答的题型：单选 / 多选 / 判断 / 填空
  static const List<String> _defaultEnabledTypes = <String>['single', 'multiple', 'judge', 'fill'];

  /// 题型别名 → 标准 key，兼容 extractor 输出中文或英文
  static const Map<String, String> _typeAliases = <String, String>{
    'single': 'single',
    'radio': 'single',
    '单选': 'single',
    '单选题': 'single',
    '单项选择': 'single',
    'multiple': 'multiple',
    'checkbox': 'multiple',
    '多选': 'multiple',
    '多选题': 'multiple',
    '多项选择': 'multiple',
    'judge': 'judge',
    'truefalse': 'judge',
    'true_false': 'judge',
    '判断': 'judge',
    '判断题': 'judge',
    'fill': 'fill',
    'blank': 'fill',
    '填空': 'fill',
    '填空题': 'fill',
  };

  InAppWebViewController? _webViewController;
  Timer? _domProbeTimer;
  final SolvingProgressController _progressController = SolvingProgressController();
  final AiSolverService _aiSolverService = AiSolverService();
  bool _isDomReady = false;

  /// 处理中标志位，防止重复点击「开始答题」并发跑多条流水线
  bool _isProcessing = false;

  /// 网页是否还能后退（缓存值，供 PopScope.canPop 同步读取）
  bool _canGoBack = false;

  /// 各 frame 主动上报的 HTML（key = frame 的 href）
  final Map<String, String> _frameHtmls = <String, String>{};

  /// 各 frame 的 document.title，用于推断课程名
  final Map<String, String> _frameTitles = <String, String>{};
  List<Map<String, dynamic>> _cachedQuestions = [];
  Completer<Map<String, dynamic>>? _extractCompleter;

  @override
  void initState() {
    super.initState();
    // 所有日志（含 setStage 的文案）镜像到 logcat，便于 adb 排障
    _progressController.logSink = (message) {
      debugPrint('[Solve] ${message.replaceAll('\n', ' ⏎ ')}');
    };
  }

  @override
  void dispose() {
    _domProbeTimer?.cancel();
    _progressController.dispose();
    super.dispose();
  }

  /// 只注入一个**只读**脚本：让每个 frame 把自身 outerHTML 抛回来，
  /// 用于「提取本页作业」把作业列表导入看板。
  /// 该脚本不点击、不修改任何 DOM，也没有任何指纹伪装。
  UnmodifiableListView<UserScript> _buildInitialUserScripts() {
    return UnmodifiableListView<UserScript>(<UserScript>[
      UserScript(
        source: _frameReporterJs,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ),
    ]);
  }

  /// 每个 frame 加载完成后主动把自身 HTML 抛回 Flutter
  static const String _frameReporterJs = r'''
    (function () {
      var posted = {};

      function post(tag) {
        try {
          var html = document.documentElement ? document.documentElement.outerHTML : '';
          if (!html || html.length < 200) return;
          if (posted[tag]) return;
          posted[tag] = true;
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('onFrameHtml', JSON.stringify({
              tag: tag,
              href: location.href,
              title: document.title || '',
              html: html
            }));
          }
        } catch (e) {}
      }

      try {
        if (document.readyState === 'complete' || document.readyState === 'interactive') {
          setTimeout(function () { post('now'); }, 500);
        }
        window.addEventListener('load', function () {
          setTimeout(function () { post('load'); }, 800);
        });
        // 异步渲染兜底：稍后再补发一次
        setTimeout(function () { post('late'); }, 3000);
      } catch (e) {}
    })();
  ''';

  void _startDomProbeTimer() {
    _domProbeTimer?.cancel();
    int attempts = 0;
    _domProbeTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (!mounted || _webViewController == null) { timer.cancel(); return; }
      if (attempts++ > 40) { timer.cancel(); _log('⚠️ 页面探测超时，未检测到题目节点'); return; }

      const String probeJs = """
        (function() {
          if (document.querySelectorAll('.TiMu, .questionLi').length > 0) return true;
          const iframes = document.querySelectorAll('iframe');
          for (var i = 0; i < iframes.length; i++) {
            try {
              var doc = iframes[i].contentDocument || iframes[i].contentWindow.document;
              if (doc && doc.querySelectorAll('.TiMu, .questionLi').length > 0) return true;
            } catch (e) {}
          }
          return false;
        })();
      """;

      try {
        final result = await _webViewController!.evaluateJavascript(source: probeJs);
        if (result == true || result.toString() == 'true') {
          timer.cancel();
          if (!mounted) return;
          setState(() => _isDomReady = true);
          _log('✅ 已探测到题目节点，可以开始答题了');
        }
      } catch (e) {
        // 页面跳转/JS 未就绪时 evaluateJavascript 可能失败，忽略继续探测
      }
    });
  }

  void _handleQuestionsExtracted(List<dynamic> args) {
    if (args.isEmpty || args.first == null) return;
    final Map<String, dynamic> payload = args.first is String ? Map<String, dynamic>.from(jsonDecode(args.first as String)) : Map<String, dynamic>.from(args.first as Map);

    final int total = (payload['totalCount'] as num?)?.toInt() ?? 0;
    final int solvable = (payload['solvableCount'] as num?)?.toInt() ?? 0;
    _cachedQuestions = List<Map<String, dynamic>>.from(payload['questions'] as List? ?? []);

    _progressController.updateQuestionStats(total, solvable);
    if (_extractCompleter != null && !_extractCompleter!.isCompleted) {
      _extractCompleter!.complete(payload);
    }
  }

  /// 子 frame 上报自身 HTML
  void _handleFrameHtml(List<dynamic> args) {
    if (args.isEmpty || args.first == null) return;
    try {
      final payload = args.first is String
          ? Map<String, dynamic>.from(jsonDecode(args.first as String) as Map)
          : Map<String, dynamic>.from(args.first as Map);
      final href = (payload['href'] ?? '').toString();
      final html = (payload['html'] ?? '').toString();
      final title = (payload['title'] ?? '').toString();
      if (html.isEmpty) return;
      final key = href.isEmpty ? 'frame_${_frameHtmls.length}' : href;
      _frameHtmls[key] = html;
      _frameTitles[key] = title;
      debugPrint('[WorkWebView] frame 上报 ${html.length} 字: $href');
    } catch (e) {
      debugPrint('[WorkWebView] frame 上报解析失败: $e');
    }
  }

  /// 界面日志（logcat 镜像由 controller 的 logSink 统一负责，
  /// 这样 setStage 里的「填涂完毕」等日志也能被 adb 抓到）
  void _log(String message) => _progressController.addLog(message);

  void _fail(String message) => _progressController.setError(message);

  Future<String> _getCookieHeader() async {
    final cookies = await CookieManager.instance().getCookies(url: WebUri(widget.workUrl));
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// 题型别名归一化
  String _canonicalType(dynamic raw) {
    final key = (raw ?? '').toString().trim().toLowerCase().replaceAll(' ', '');
    return _typeAliases[key] ?? key;
  }

  /// 过滤出参与自动作答的题目，并把 type 统一成标准 key
  List<Map<String, dynamic>> _filterQuestionsByTypes(List<String> enabledTypes) {
    final allowed = enabledTypes.map(_canonicalType).toSet();
    final filtered = <Map<String, dynamic>>[];

    for (final question in _cachedQuestions) {
      final canonical = _canonicalType(question['type']);
      if (!allowed.contains(canonical)) continue;
      filtered.add(<String, dynamic>{...question, 'type': canonical});
    }
    return filtered;
  }

  /// 读取当前页题目 → 请求 AI → 以清单形式展示参考答案。
  ///
  /// 注意：本方法**只读页面**，不会点击选项、不会写入富文本、不会点保存。
  /// 用户需要自己对照清单在网页上作答。
  Future<void> _startAiReading({
    List<String> enabledTypes = _defaultEnabledTypes,
  }) async {
    if (_isProcessing) {
      _log('正在处理中，请勿重复点击');
      return;
    }
    if (_webViewController == null) return;

    _isProcessing = true;
    _progressController.reset();

    try {
      _progressController.setStage(
        SolvingStage.extracting,
        logMessage: '正在读取页面题目（仅文字）...',
      );
      _extractCompleter = Completer<Map<String, dynamic>>();
      await _webViewController!
          .injectJavascriptFileFromAsset(assetFilePath: 'assets/js/extractor.js');
      await _extractCompleter!.future.timeout(const Duration(seconds: 10));

      if (_cachedQuestions.isEmpty) throw Exception('未提取到任何题目');

      // 只把目标题型交给 AI，避免把整页无关内容都发出去
      final solvableQuestions = _filterQuestionsByTypes(enabledTypes);
      final skippedCount = _cachedQuestions.length - solvableQuestions.length;
      if (skippedCount > 0) {
        _log('题型过滤：跳过 $skippedCount 道非目标题型（仅处理 ${enabledTypes.join('/')}）');
      }
      if (solvableQuestions.isEmpty) {
        throw Exception('过滤后没有可分析的题目（enabledTypes: ${enabledTypes.join(',')}）');
      }

      _progressController.setStage(
        SolvingStage.thinking,
        logMessage: '正在请求 AI 分析（${solvableQuestions.length} 道题）...',
      );
      final cookieHeader = await _getCookieHeader();

      final List<Map<String, dynamic>> answers;
      try {
        answers = await _aiSolverService
            .solveQuestions(
              questions: solvableQuestions,
              models: AppConfig.getLlmModels(),
              cookieHeader: cookieHeader,
              userAgent: _desktopUA,
              onLog: _log,
            )
            .timeout(const Duration(seconds: 100));
      } on TimeoutException {
        _fail('AI 请求超时，请重试');
        return;
      }

      if (answers.isEmpty) throw Exception('AI 未返回任何答案');

      _progressController.setStage(
        SolvingStage.completed,
        logMessage: '已生成 ${answers.length} 条参考答案，请对照页面自行填写',
      );

      await _showAnswerSheet(answers, solvableQuestions);
    } catch (e) {
      _fail(e.toString());
    } finally {
      _isProcessing = false;
    }
  }

  /// 题型的中文标签
  String _answerTypeLabel(dynamic raw) {
    switch (_canonicalType(raw)) {
      case 'single':
        return '单选';
      case 'multiple':
        return '多选';
      case 'judge':
        return '判断';
      case 'fill':
        return '填空';
      default:
        return '题目';
    }
  }

  /// 把答案格式化成一行文本（多选是数组）
  String _formatAnswer(dynamic raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).join('、');
    }
    return (raw ?? '').toString();
  }

  /// 底部弹窗展示「第 N 题：答案」。纯展示，不操作网页。
  Future<void> _showAnswerSheet(
    List<Map<String, dynamic>> answers,
    List<Map<String, dynamic>> questions,
  ) async {
    final questionByIndex = <int, Map<String, dynamic>>{};
    for (final q in questions) {
      final index = (q['index'] as num?)?.toInt();
      if (index != null) questionByIndex[index] = q;
    }

    final sorted = List<Map<String, dynamic>>.from(answers)
      ..sort((a, b) {
        final ai = (a['index'] as num?)?.toInt() ?? 0;
        final bi = (b['index'] as num?)?.toInt() ?? 0;
        return ai.compareTo(bi);
      });

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.72;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  'AI 参考答案（共 ${sorted.length} 条）',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  '本工具不会自动作答或操作网页，请对照下面的答案自行在页面中作答。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: sorted.length,
                    separatorBuilder: (context, index) => const Divider(height: 18),
                    itemBuilder: (context, idx) {
                      final answer = sorted[idx];
                      final index = (answer['index'] as num?)?.toInt() ?? idx + 1;
                      final question = questionByIndex[index];
                      final stem = (question?['stem'] ?? '').toString();
                      final type = _answerTypeLabel(
                        answer['type'] ?? question?['type'],
                      );

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.06),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$index',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '第 $index 题 · $type：${_formatAnswer(answer['answer'])}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (stem.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 4),
                                  Text(
                                    stem,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      height: 1.4,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('我知道了，去手动填写'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 刷新缓存的「能否后退」状态
  Future<void> _syncCanGoBack() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      final canGoBack = await controller.canGoBack();
      if (!mounted) return;
      if (canGoBack != _canGoBack) {
        setState(() => _canGoBack = canGoBack);
      }
    } catch (e) {
      // 页面正在跳转时查询可能失败，忽略
    }
  }

  /// 抓取当前页 HTML（含 iframe 内容）+ 课程名，解析成任务后回传给看板
  Future<void> _extractTasksFromCurrentPage() async {
    final controller = _webViewController;
    if (controller == null) {
      _showSnack('页面还没准备好，请稍候再试');
      return;
    }

    try {
      _log('正在提取本页作业…');

      final items = <HomeworkItem>[];
      final seenUrls = <String>{};

      // ---------- 方案 1：用各 frame 自报的 HTML ----------
      // 学习通把作业列表放在内容区 iframe（跨域），顶层读不到 contentDocument，
      // 所以靠注入脚本让子 frame 自己把 outerHTML 抛回来。
      final courseName = _guessCourseName();

      for (final html in _frameHtmls.values) {
        final parsed = ScannerService.instance.parseTasksFromHtml(html, courseName: courseName);
        for (final item in parsed) {
          if (seenUrls.add(item.url)) items.add(item);
        }
      }
      _log('frame 快照 ${_frameHtmls.length} 个 → ${items.length} 条作业');

      // ---------- 方案 2：都没有就抓当前帧 ----------
      if (items.isEmpty) {
        final CallAsyncJavaScriptResult? dumpResult = await controller.callAsyncJavaScript(
          functionBody: r"""
            var html = document.documentElement ? document.documentElement.outerHTML : '';
            return JSON.stringify({ href: location.href, html: html });
          """,
        );

        final dynamic raw = dumpResult?.value;
        if (raw != null) {
          final payload = Map<String, dynamic>.from(jsonDecode(raw.toString()) as Map);
          final html = (payload['html'] ?? '').toString();
          if (html.isNotEmpty) {
            final parsed = ScannerService.instance.parseTasksFromHtml(html, courseName: courseName);
            for (final item in parsed) {
              if (seenUrls.add(item.url)) items.add(item);
            }
            _log('当前帧解析到 ${items.length} 条作业');
          }
        }
      }

      if (items.isEmpty) {
        _showSnack('本页没解析到作业：请先点进课程里的「作业」列表，等它加载出来再点提取');
        return;
      }

      if (!mounted) return;
      // 把结果回传给看板（通过路由返回值接收）
      Navigator.of(context).pop(items);
    } catch (e) {
      _log('❌ 提取失败: $e');
      _showSnack('提取失败：$e');
    }
  }

  /// 推断课程名：先从各 frame 的 HTML 里找课程名节点，再退化到 document.title
  String _guessCourseName() {
    final patterns = <RegExp>[
      RegExp(r'class="[^"]*course-?name[^"]*"[^>]*>\s*([^<]{2,40})<', caseSensitive: false),
      RegExp(r'id="courseName"[^>]*>\s*([^<]{2,40})<', caseSensitive: false),
    ];

    for (final html in _frameHtmls.values) {
      for (final pattern in patterns) {
        final match = pattern.firstMatch(html);
        final value = match?.group(1)?.trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }

    const generic = <String>{
      '作业', '任务', '考试', '学习通', '超星学习通', '我的课程', '课程',
      '章节', '资料', '讨论', '任务列表', '作业列表', '考试列表',
    };

    // 各 frame 的 title 里，课程名通常最长（"英语四六级刷题冲刺" > "任务列表"）
    final candidates = <String>[];
    for (final title in _frameTitles.values) {
      var value = title.trim();
      if (value.isEmpty || generic.contains(value)) continue;
      value = value.split(RegExp(r'\s+|、|\|')).first.trim();
      if (value.isEmpty || generic.contains(value)) continue;
      candidates.add(value);
    }

    if (candidates.isEmpty) return widget.workTitle;
    candidates.sort((a, b) => b.length.compareTo(a.length));
    return candidates.first;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  /// 统一的返回逻辑：网页能后退就后退，退无可退才关闭本页
  Future<void> _handleBack() async {
    // 先取出 navigator，避免 await 之后再碰 context
    final navigator = Navigator.of(context);
    final controller = _webViewController;

    if (controller != null) {
      try {
        if (await controller.canGoBack()) {
          await controller.goBack();
          await _syncCanGoBack();
          return;
        }
      } catch (e) {
        debugPrint('[WorkWebView] 网页后退失败，改为退出页面: $e');
      }
    }

    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 网页还有历史记录时拦截系统返回键，交给 _handleBack 先做网页后退
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(widget.workTitle),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
        // 返回按钮与系统返回键走同一套逻辑
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: _handleBack,
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.playlist_add_check),
            tooltip: '提取本页作业',
            onPressed: _extractTasksFromCurrentPage,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.workUrl)),
                    // 唯一的注入脚本：只读上报 frame HTML（用于导入作业列表）
                    initialUserScripts: _buildInitialUserScripts(),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      userAgent: _desktopUA,
                      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                      useWideViewPort: true,
                      loadWithOverviewMode: true,
                    ),
                    onWebViewCreated: (controller) {
                      _webViewController = controller;
                      controller.addJavaScriptHandler(handlerName: 'onQuestionsExtracted', callback: _handleQuestionsExtracted);
                      controller.addJavaScriptHandler(handlerName: 'onFrameHtml', callback: _handleFrameHtml);
                    },
                    onLoadStop: (controller, url) async {
                      // 新页面：清掉上一页的 frame 快照，等这次上报
                      _frameHtmls.clear();
                      _frameTitles.clear();
                      _log('页面加载完成，正在探测题目节点...');
                      _startDomProbeTimer();
                      _syncCanGoBack();
                    },
                    onUpdateVisitedHistory: (controller, url, isReload) {
                      _syncCanGoBack();
                    },
                    onJsAlert: (controller, jsAlertRequest) async {
                      _log('拦截弹窗: ${jsAlertRequest.message}');
                      return JsAlertResponse(handledByClient: true, action: JsAlertResponseAction.CONFIRM);
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
            child: SafeArea(
              top: false,
              child: SolvingBottomSheet(
                controller: _progressController,
                // 默认只自动作答单选/多选/判断/填空
                onStartPressed: _isDomReady
                    ? () => _startAiReading(
                          enabledTypes: const ['single', 'multiple', 'judge', 'fill'],
                        )
                    : () {},
              ),
            ),
          ),
        ],
      ),
    );
  }
}
