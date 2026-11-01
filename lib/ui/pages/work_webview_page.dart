import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/config/app_config.dart';
import '../../data/services/ai_solver_service.dart';
import '../../data/services/course_store.dart';
import '../../data/services/scanner_service.dart';
import '../../data/services/submission_detector.dart';
import '../theme/app_theme.dart';
import '../widgets/answer_float_panel.dart';

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
  static const String _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 默认参与自动作答的题型：单选 / 多选 / 判断 / 填空
  static const List<String> _defaultEnabledTypes = <String>[
    'single',
    'multiple',
    'judge',
    'fill',
  ];

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
  final SolvingProgressController _progressController =
      SolvingProgressController();
  final AiSolverService _aiSolverService = AiSolverService();
  bool _isDomReady = false;

  /// 当前展示的参考答案（为空表示还没生成）
  List<AnswerEntry> _answers = const <AnswerEntry>[];

  /// 这批答案是哪个地址出来的。换作业后旧答案必须失效，
  /// 否则用户会对着上一份作业的答案抄。
  String? _answersUrl;

  /// 当前 WebView 地址（由加载回调维护，避免在同步代码里 await getUrl）
  String? _currentPageUrl;

  /// 只读的页面状态指纹：表单控件数量 + 它们当前值的总长度 + 元素节点总数。
  ///
  /// **全程只读**（`input.value` 也只读取不赋值），
  /// 用来在运行前后各采一次，向用户证明本 App 没有改动网页。
  /// 只扫顶层文档，不穿透 iframe——与提取脚本保持同一原则。
  /// 刻意**不读 innerHTML / outerHTML**，只数节点，连一字节页面内容都不带回。
  static const String _fingerprintBody = r'''
    var fields = document.querySelectorAll('input, textarea, select');
    var valueLen = 0;
    for (var i = 0; i < fields.length; i++) {
      var v = fields[i].value || '';
      valueLen += v.length;
    }
    return JSON.stringify({
      fields: fields.length,
      valueLen: valueLen,
      nodes: document.getElementsByTagName('*').length
    });
  ''';

  /// 处理中标志位，防止重复点击「开始答题」并发跑多条流水线
  bool _isProcessing = false;

  /// 网页是否还能后退（缓存值，供 PopScope.canPop 同步读取）
  bool _canGoBack = false;

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

  /// 页面加载阶段**不做任何采集**：
  /// 不注入脚本、不注册 frame 上报桥、不自动 dump 页面内容。
  /// 所有读取都发生在用户点按钮的那一次调用里（见 [_readPageRows]）。

  void _startDomProbeTimer() {
    _domProbeTimer?.cancel();
    int attempts = 0;
    _domProbeTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (!mounted || _webViewController == null) {
        timer.cancel();
        return;
      }
      if (attempts++ > 40) {
        timer.cancel();
        _log('⚠️ 页面探测超时，未检测到题目节点');
        return;
      }

      // 只看顶层文档：与提取脚本保持同一边界，不遍历 iframe。
      // 题目若在跨域 iframe 里，本工具本来也提取不到，按钮就不该点亮。
      const String probeJs = """
        document.querySelectorAll('.TiMu, .questionLi').length > 0
      """;

      try {
        final result = await _webViewController!.evaluateJavascript(
          source: probeJs,
        );
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
    if (args.length != 1 || args.first == null) return;

    final payload = _decodeBridgePayload(args.first);
    if (payload == null) {
      // 超长在解码处已经报过准确提示，这里不再叠一条含糊的「结构不符」
      if (_bridgeRejectedBySize) {
        _bridgeRejectedBySize = false;
        return;
      }
      _log('⚠️ 提取脚本回传的数据结构不符合预期，本次已忽略');
      return;
    }

    final questions = <Map<String, dynamic>>[];
    final rawQuestions = payload['questions'];
    if (rawQuestions is List) {
      for (final raw in rawQuestions) {
        if (questions.length >= _bridgeMaxQuestions) break;
        final question = _sanitizeQuestion(raw);
        if (question != null) questions.add(question);
      }
    }

    final collapsed = payload['collapsedCount'] is num
        ? (payload['collapsedCount'] as num).toInt()
        : 0;

    _cachedQuestions = questions;
    final int total = questions.length;

    if (collapsed > 0) {
      _log('去重：折叠了 $collapsed 个子块，同一大题的多个空只算一题');
    }
    _progressController.updateQuestionStats(total, total);
    if (_extractCompleter != null && !_extractCompleter!.isCompleted) {
      _extractCompleter!.complete(<String, dynamic>{
        'questions': questions,
        'totalCount': total,
      });
    }
  }

  /// 桥接回传数据的硬上限：超过就整包丢弃，不做「尽力解析」。
  ///
  /// 体积一律按 **UTF-8 实际字节数** 计（[utf8.encode] 后的 length）。
  /// 只数字符数是挡不住的：一个汉字在 UTF-8 里占 3 字节，
  /// 200K 字符的中文载荷最坏能到 600KB。
  static const int _bridgeMaxPayloadBytes = 200 * 1024;

  /// 原有的字符数上限，保留作为第一道快速短路（先按字符数挡，再按字节复核）
  static const int _bridgeMaxPayloadChars = 200 * 1024;
  static const int _bridgeMaxQuestions = 300;
  static const int _bridgeMaxStemChars = 2000;
  static const int _bridgeMaxOptions = 12;
  static const int _bridgeMaxOptionChars = 500;

  /// 上一次解码是否因「超长」被拒。
  ///
  /// 只为了给用户一条准确的提示（超长 vs 结构不符），每次解码前重置。
  bool _bridgeRejectedBySize = false;

  /// 把网页交回来的东西解成 Map。
  ///
  /// 只接受「Map」或「长度受限的 JSON 字符串」，其余类型（数字、数组、
  /// 超长字符串）一律当非法数据丢弃——这一层不信任网页侧的任何输入。
  ///
  /// **两条入口共用同一道体积闸**：Map 先序列化成 JSON 文本，再和字符串
  /// 入口一样按 UTF-8 字节数计量，不存在「绕过 Map 就不查大小」的路径。
  Map<String, dynamic>? _decodeBridgePayload(dynamic raw) {
    _bridgeRejectedBySize = false;

    final String text;
    if (raw is String) {
      // ---- 入口 1：字符串（网页脚本的常规形态）----
      text = raw;
    } else if (raw is Map) {
      // ---- 入口 2：Map（插件在部分平台会直接交出已解析对象）----
      // 键统一成 String（与旧行为一致）后再序列化；循环引用 / 含不可编码
      // 对象（Function、DateTime 等）时 jsonEncode 会抛，直接整包丢弃。
      final normalized = <String, dynamic>{};
      try {
        raw.forEach((k, v) => normalized[k.toString()] = v);
        text = jsonEncode(normalized);
      } catch (e) {
        debugPrint('[WorkWebView] 桥接 Map 序列化失败，已丢弃: ${e.runtimeType}');
        return null;
      }
    } else {
      return null;
    }

    if (text.isEmpty) return null;

    if (!_bridgePayloadWithinLimit(text)) {
      _bridgeRejectedBySize = true;
      _log('⚠️ 桥接数据超长，已拦截');
      return null;
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      return null;
    }
  }

  /// 体积闸门：先按字符数快速短路，再按 UTF-8 实际字节数复核。
  ///
  /// 任何一步不通过都返回 false（宁可丢包，不做「截断后尽力解析」）。
  static bool _bridgePayloadWithinLimit(String text) {
    if (text.length > _bridgeMaxPayloadChars) return false;
    try {
      return utf8.encode(text).length <= _bridgeMaxPayloadBytes;
    } catch (e) {
      // utf8.encode 正常不会抛；真抛了按超限处理
      return false;
    }
  }

  /// 单题清洗：只保留白名单字段，类型/长度不符的直接丢弃
  Map<String, dynamic>? _sanitizeQuestion(dynamic raw) {
    if (raw is! Map) return null;

    final stem = _bridgeText(raw['stem'], _bridgeMaxStemChars);
    if (stem.isEmpty) return null;

    final options = <Map<String, String>>[];
    final rawOptions = raw['options'];
    if (rawOptions is List) {
      for (final option in rawOptions) {
        if (options.length >= _bridgeMaxOptions) break;
        if (option is Map) {
          final text = _bridgeText(option['text'], _bridgeMaxOptionChars);
          if (text.isEmpty) continue;
          options.add(<String, String>{
            'label': _bridgeText(option['label'], 2),
            'text': text,
          });
        } else {
          final text = _bridgeText(option, _bridgeMaxOptionChars);
          if (text.isEmpty) continue;
          options.add(<String, String>{'label': '', 'text': text});
        }
      }
    }

    return <String, dynamic>{
      'index': raw['index'] is num ? (raw['index'] as num).toInt() : 0,
      'type': _bridgeText(raw['type'], 16),
      'stem': stem,
      'options': options,
      'blankCount': raw['blankCount'] is num
          ? (raw['blankCount'] as num).toInt()
          : 0,
    };
  }

  /// 只接受标量，压空白并截断；Map / List / 超长内容一律不接
  static String _bridgeText(dynamic value, int max) {
    if (value == null || value is Map || value is List) return '';
    final text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '';
    return text.length > max ? text.substring(0, max) : text;
  }

  /// 界面日志（logcat 镜像由 controller 的 logSink 统一负责，
  /// 这样 setStage 里的「填涂完毕」等日志也能被 adb 抓到）
  void _log(String message) => _progressController.addLog(message);

  void _fail(String message) => _progressController.setError(message);

  /// 题型别名归一化
  String _canonicalType(dynamic raw) {
    final key = (raw ?? '').toString().trim().toLowerCase().replaceAll(' ', '');
    return _typeAliases[key] ?? key;
  }

  /// 过滤出参与自动作答的题目，并把 type 统一成标准 key
  List<Map<String, dynamic>> _filterQuestionsByTypes(
    List<String> enabledTypes,
  ) {
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

    // 已交作业拦截：先只读判断一次，已提交就别浪费 AI 额度
    if (await _guardSubmittedWork()) return;

    _isProcessing = true;
    _progressController.reset();
    // 新一轮开始：先清掉上一轮的答案，避免旧答案混进来
    if (mounted) setState(() => _answers = const <AnswerEntry>[]);

    // 流水线开始前先采一次页面指纹
    final fingerprintBefore = await _readFingerprint();

    try {
      _progressController.setStage(
        SolvingStage.extracting,
        logMessage: '正在读取页面题目（仅文字）...',
      );
      _extractCompleter = Completer<Map<String, dynamic>>();
      await _webViewController!.injectJavascriptFileFromAsset(
        assetFilePath: 'assets/js/extractor.js',
      );
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

      final List<Map<String, dynamic>> answers;
      try {
        answers = await _aiSolverService
            .solveQuestions(
              questions: solvableQuestions,
              models: AppConfig.getLlmModels(),
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

      final fingerprintAfter = await _readFingerprint();
      _reportFingerprint(fingerprintBefore, fingerprintAfter);

      _publishAnswers(answers, solvableQuestions);
    } catch (e) {
      // 失败时也做一次比对，保证每次运行都有可核对的记录
      final fingerprintAfter = await _readFingerprint();
      _reportFingerprint(fingerprintBefore, fingerprintAfter);
      _fail(e.toString());
    } finally {
      _isProcessing = false;
    }
  }

  // ---------------- 已交作业拦截 ----------------

  /// 只读探测「这份作业是不是已经交了」。
  ///
  /// 判据都不写页面：
  ///  - 题目块存在，但页面上**一个可编辑控件都没有**（radio / checkbox / textarea
  ///    全部 disabled 或 readonly）→ 这是提交后的只读视图；
  ///  - 或者页面同时出现「我的答案」和「正确答案 / 参考答案」→ 批阅后的对答案视图；
  ///  - 或者页面出现「已完成 / 已交」并且带分数 → 已批阅。
  static const String _submissionProbeBody = r'''
    var blocks = document.querySelectorAll('.TiMu, .questionLi');
    var editable = document.querySelectorAll(
      'textarea:not([readonly]):not([disabled]),' +
      'input[type="text"]:not([readonly]):not([disabled]),' +
      'input[type="radio"]:not([disabled]),' +
      'input[type="checkbox"]:not([disabled]),' +
      '[contenteditable="true"]'
    ).length;
    var text = (document.body && document.body.innerText) ? document.body.innerText : '';
    var hits = [];
    ['已提交', '已完成', '已交', '待批阅', '已批阅', '已通过'].forEach(function (w) {
      if (text.indexOf(w) >= 0) hits.push(w);
    });
    var answerView = text.indexOf('我的答案') >= 0 &&
      (text.indexOf('正确答案') >= 0 || text.indexOf('参考答案') >= 0);
    var score = /\d+(\.\d+)?\s*分/.test(text);
    return JSON.stringify({
      questions: blocks.length,
      editable: editable,
      hits: hits.join(','),
      answerView: answerView,
      score: score
    });
  ''';

  Future<Map<String, dynamic>?> _probeSubmission() async {
    final controller = _webViewController;
    if (controller == null) return null;
    try {
      final result = await controller.callAsyncJavaScript(
        functionBody: _submissionProbeBody,
      );
      final raw = (result?.value ?? '').toString();
      if (raw.isEmpty || raw == 'null') return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      // 页面正在跳转时可能失败：判不出来就放行，不误拦
      debugPrint('[WorkWebView] 提交状态探测失败: $e');
      return null;
    }
  }

  /// 页面状态 → 是否已交。判据抽在 [looksSubmittedFromProbe]（纯函数，可单测）。
  bool _looksSubmitted(Map<String, dynamic> state) =>
      looksSubmittedFromProbe(state);

  /// 已交就弹窗拦下，返回 true 表示「别继续了」
  Future<bool> _guardSubmittedWork() async {
    // 一、先看地址：
    //    /work/view  → 已提交的只读视图
    //    /work/dowork、/work/task → 正在作答，绝不能拦（作文题的编辑器在 iframe 里，
    //    页面探测会误判成「没有可填控件」，所以这里直接放行、不再探测）
    var submitted = false;
    var kind = WorkPageKind.unknown;
    try {
      final url = (await _webViewController?.getUrl())?.toString() ?? '';
      kind = workPageKindFromUrl(url);
      if (kind == WorkPageKind.submitted) {
        submitted = true;
        _log('⛔ 当前是已提交作业的只读视图，已拦下这次 AI 请求（不消耗额度）');
      }
    } catch (e) {
      debugPrint('[WorkWebView] 读取当前地址失败: $e');
    }

    // 二、地址看不出来时再看页面：题目全只读，或出现「我的答案 + 正确答案」
    if (kind == WorkPageKind.unknown) {
      final state = await _probeSubmission();
      submitted = state != null && _looksSubmitted(state);
      if (submitted) {
        _log('⛔ 页面显示作业已提交，已拦下这次 AI 请求（不消耗额度）');
      }
    }

    if (!submitted) return false;
    if (!mounted) return true;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.verified_rounded, color: AppColors.success),
        title: const Text('当前作业已完成'),
        content: const Text(
          '当前作业已完成，无需提取。\n\n'
          '网页上这份作业已经是提交/批阅后的只读状态，这次不会发起 AI 请求。',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return true;
  }

  /// 只读采集页面指纹（连 input.value 都只读取，绝不赋值）
  Future<String> _readFingerprint() async {
    final controller = _webViewController;
    if (controller == null) return '';
    try {
      final result = await controller.callAsyncJavaScript(
        functionBody: _fingerprintBody,
      );
      return (result?.value ?? '').toString();
    } catch (e) {
      return '';
    }
  }

  /// 比对运行前后的页面指纹，把结论打到日志面板上
  void _reportFingerprint(String before, String after) {
    // 采不到就不装「一切正常」：明确告诉用户这次没能自证
    if (before.isEmpty || after.isEmpty) {
      _log('⚠️ 指纹采集失败，本次无法自证网页未修改');
      return;
    }

    if (before == after) {
      _log('🔒 页面指纹一致 $before —— 网页未被修改');
    } else {
      _log('⚠️ 页面指纹变化：$before → $after');
      _log('   本 App 全程只读不写，变化来自网页自身的刷新/懒加载');
    }
  }

  /// 题型的中文标签
  String _answerTypeLabel(dynamic raw, {String stem = ''}) {
    final label = _typeLabelOf(raw);
    // 简答/翻译/作文在页面上常被标成 fill，光看类型会显示成「填空」，
    // 容易让人以为只要有词组答案。看题干开头再细分一下。
    if (label == '填空') {
      final head = stem.length > 24 ? stem.substring(0, 24) : stem;
      if (RegExp(r'简答|问答|翻译|写作|作文|论述|名词解释').hasMatch(head)) {
        return '简答';
      }
    }
    return label;
  }

  String _typeLabelOf(dynamic raw) {
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

  /// 把 AI 的答案整理成面板条目，就地展示（不再弹模态框）。
  /// 纯展示：不写页面、不点按钮。
  void _publishAnswers(
    List<Map<String, dynamic>> answers,
    List<Map<String, dynamic>> questions,
  ) {
    final questionByIndex = <int, Map<String, dynamic>>{};
    for (final q in questions) {
      final index = (q['index'] as num?)?.toInt();
      if (index != null) questionByIndex[index] = q;
    }

    final ordered = List<Map<String, dynamic>>.from(answers)
      ..sort((a, b) {
        final ai = (a['index'] as num?)?.toInt() ?? 0;
        final bi = (b['index'] as num?)?.toInt() ?? 0;
        return ai.compareTo(bi);
      });

    // 兜底去重：index + 答案完全相同的记录只保留一条，
    // 避免 AI 对同一道大题吐出多条一模一样的答案
    final seen = <String>{};
    final entries = <AnswerEntry>[];
    for (final answer in ordered) {
      final index = (answer['index'] as num?)?.toInt() ?? 0;
      final text = _formatAnswer(answer['answer']);
      if (!seen.add('$index|$text')) continue;
      entries.add(
        AnswerEntry(
          index: index,
          typeLabel: _answerTypeLabel(
            answer['type'] ?? questionByIndex[index]?['type'],
            stem: (questionByIndex[index]?['stem'] ?? '').toString(),
          ),
          answer: text,
          stem: (questionByIndex[index]?['stem'] ?? '').toString(),
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _answers = entries;
      _answersUrl = _currentPageUrl;
    });
  }

  /// 换了页面（地址变了）就把上一份答案清掉。
  /// 只是同页刷新时地址不变，答案保留，不会白跑一次 AI。
  void _dropStaleAnswers(String? url) {
    if (_answers.isEmpty) return;
    if (url == null || url == _answersUrl) return;
    _progressController.reset();
    setState(() => _answers = const <AnswerEntry>[]);
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

  // ---------------- 用户点击后才读页面 ----------------

  /// 作业行 / 课程卡片的读取脚本（只在用户点击按钮后注入）
  static const String _pageReaderAsset = 'assets/js/page_reader.js';

  /// 单次读取最多接受的字符数与行数
  static const int _maxPageRowsPayloadChars = 100 * 1024;
  static const int _maxPageRows = 300;

  /// 用户点「提取作业 / 保存全部」后才执行一次，读的是**字段**而不是 HTML。
  ///
  /// 数据最小化（本轮 P0 的重点）：
  ///  - 网页侧（`page_reader.js`）直接从 DOM 里挑标题 / 状态 / 截止时间这几段
  ///    可见文字，加上行上的 data 链接，拼成 JSON；
  ///  - **不再传 `outerHTML`**，也不传 innerHTML、隐藏表单字段、Cookie、
  ///    内部无关 id / class；
  ///  - 只读顶层文档，不遍历 iframe；
  ///  - 日志只打域名（脚本直接给 `location.host`），带 stuenc / courseId 的
  ///    完整地址既不进 Dart 也不进日志。
  ///
  /// [accessor] 是脚本暴露的两个方法名之一：`tasks`（作业行）/ `courses`（课程卡片）。
  Future<_PageRows?> _readPageRows(String accessor) async {
    final controller = _webViewController;
    if (controller == null) return null;

    try {
      await controller.injectJavascriptFileFromAsset(
        assetFilePath: _pageReaderAsset,
      );

      final result = await controller.callAsyncJavaScript(
        functionBody: """
          if (!window.__cxPageReader ||
              typeof window.__cxPageReader.$accessor !== 'function') {
            return '';
          }
          return JSON.stringify(window.__cxPageReader.$accessor());
        """,
      );

      final raw = (result?.value ?? '').toString();
      if (raw.isEmpty || raw == 'null') return null;
      if (raw.length > _maxPageRowsPayloadChars) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = Map<String, dynamic>.from(decoded);

      final rows = <Map<String, dynamic>>[];
      final rawRows = payload['rows'];
      if (rawRows is List) {
        for (final row in rawRows) {
          if (rows.length >= _maxPageRows) break;
          if (row is Map) {
            rows.add(Map<String, dynamic>.from(row));
          }
        }
      }

      return _PageRows(
        host: _safeHost(payload['host']),
        pageTitle: _bridgeText(payload['pageTitle'], 120),
        courseName: _bridgeText(payload['courseName'], 40),
        rows: rows,
      );
    } catch (e) {
      debugPrint('[WorkWebView] 读取页面结构化数据失败: $e');
      return null;
    }
  }

  /// 域名只留 host 字符集：防止日志里混进路径、参数或换行
  static String _safeHost(dynamic value) {
    final text = _bridgeText(value, 80).toLowerCase();
    if (text.isEmpty) return '未知域名';
    return RegExp(r'^[a-z0-9.\-]+$').hasMatch(text) ? text : '未知域名';
  }

  /// 「提取作业」：只有用户点这个按钮，才会去读当前页 DOM 并解析成任务。
  Future<void> _extractTasksFromCurrentPage() async {
    final controller = _webViewController;
    if (controller == null) {
      _showSnack('页面还没准备好，请稍候再试');
      return;
    }

    // 已交作业拦截：这份作业已经提交/批阅，提了也没意义，别浪费后续 AI 请求
    if (await _guardSubmittedWork()) return;

    try {
      _log('正在读取本页作业…');

      final page = await _readPageRows('tasks');
      if (page == null || page.rows.isEmpty) {
        _showSnack('没读到作业行，请等作业列表加载出来再点一次');
        return;
      }
      _log('已读到 ${page.rows.length} 行作业（域名 ${page.host}）');

      final courseName = _guessCourseName(page.courseName, page.pageTitle);
      final items = ScannerService.instance.parseTaskRows(
        page.rows,
        courseName: courseName,
      );
      _log('解析到 ${items.length} 条作业');

      if (items.isEmpty) {
        _showSnack('本页没解析到作业：请先点进课程里的「作业」列表，等它加载出来再点提取');
        return;
      }

      // 顺手把这门课记进快捷入口：下次直接跳回这个页面
      final currentUrl = (await controller.getUrl())?.toString() ?? '';
      await _rememberCourseFromUrl(currentUrl, courseName);

      if (!mounted) return;
      // 把结果回传给看板（通过路由返回值接收）
      Navigator.of(context).pop(items);
    } catch (e) {
      _log('❌ 提取失败: $e');
      _showSnack('提取失败：$e');
    }
  }

  /// 推断课程名：先用网页给的课程名节点文字，再退化到 document.title
  String _guessCourseName(String hint, String title) {
    final fromHint = _cleanCourseName(hint);
    if (fromHint.isNotEmpty) return fromHint;

    const generic = <String>{
      '作业',
      '任务',
      '考试',
      '学习通',
      '超星学习通',
      '我的课程',
      '课程',
      '章节',
      '资料',
      '讨论',
      '任务列表',
      '作业列表',
      '考试列表',
    };

    var value = title.trim();
    if (value.isEmpty || generic.contains(value)) return widget.workTitle;
    value = value.split(RegExp(r'\s+|、|\|')).first.trim();
    if (value.isEmpty || generic.contains(value)) return widget.workTitle;
    return value;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          // 悬浮式：避免被底部的进度面板盖住
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 190),
        ),
      );
  }

  /// 课程名黑名单：这些是页面标题/通用文案，不是课程名
  static const Set<String> _genericNames = <String>{
    '作业',
    '任务',
    '考试',
    '学习通',
    '超星学习通',
    '我的课程',
    '课程',
    '章节',
    '资料',
    '讨论',
    '任务列表',
    '作业列表',
    '考试列表',
    '收件箱',
    '首页',
    '互动',
    '待办',
  };

  /// 去掉页面标题里的噪音，留下像课程名的那部分
  String _cleanCourseName(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    value = value.split(RegExp(r'\s+|、|\||-')).first.trim();
    if (value.isEmpty || _genericNames.contains(value)) return '';
    return value;
  }

  /// 把当前页面地址记成这门课的入口。
  ///
  /// 在学习通里，课程页/作业列表页的 URL 上带着 courseId、classId，
  /// 很多时候还带 enc。存下来后，主页的快捷卡片就能直接跳回这个页面。
  Future<void> _rememberCourseFromUrl(String rawUrl, String courseName) async {
    final ref = CourseRef.fromUrl(rawUrl);
    if (ref == null) return;

    final name = _cleanCourseName(courseName);
    try {
      await CourseStore.upsertMany(<CourseRef>[
        CourseRef(
          courseName: name,
          courseId: ref.courseId,
          classId: ref.classId,
          cpi: ref.cpi,
          enc: ref.enc,
          homeUrl: ref.homeUrl,
        ),
      ]);
    } catch (e) {
      debugPrint('[WorkWebView] 记录课程失败: $e');
    }
  }

  /// 「保存全部课程」：用户点击后只读一次当前页 DOM，把整页课程卡片存成快捷入口。
  ///
  /// 全程不点击、不跳转、不修改 DOM——只是把页面上已经渲染好的
  /// `<a class="color1">` 课程链接读出来。
  Future<void> _importCoursesFromCurrentPage() async {
    final controller = _webViewController;
    if (controller == null) {
      _showSnack('页面还没准备好，请稍候再试');
      return;
    }

    try {
      _log('正在读取本页课程…');

      // 点击这一次才读页面，不做任何后台/加载期采集
      final page = await _readPageRows('courses');
      if (page == null) {
        _showSnack('没读到页面内容，请等网页加载完再点一次');
        return;
      }

      // 网页侧只给「课程名 + 卡片链接」，不再交 HTML
      final collected = ScannerService.instance.parseCourseRows(page.rows);
      final seen = collected.map((c) => c.key).toSet();
      final courseName = _guessCourseName(page.courseName, page.pageTitle);

      // 兜底：直接解析当前地址（单门课）
      if (collected.isEmpty) {
        final url = (await controller.getUrl())?.toString() ?? '';
        final ref = CourseRef.fromUrl(url);
        if (ref != null && seen.add(ref.key)) {
          collected.add(
            CourseRef(
              courseName: _cleanCourseName(courseName),
              courseId: ref.courseId,
              classId: ref.classId,
              cpi: ref.cpi,
              enc: ref.enc,
              homeUrl: ref.homeUrl,
            ),
          );
        }
      }

      if (collected.isEmpty) {
        _showSnack(
          '本页没解析到课程：请先在网页里打开「课程列表」页面，'
          '等课程卡片显示出来再点这里',
        );
        return;
      }

      final added = await CourseStore.upsertMany(collected);
      _log('✅ 课程入口：共 ${collected.length} 门，新增 $added 门');
      _showSnack(
        added > 0
            ? '已保存 ${collected.length} 门课程（新增 $added 门）'
            : '这 ${collected.length} 门课程已经在列表里了',
      );
    } catch (e) {
      _log('❌ 课程导入失败: $e');
      _showSnack('课程导入失败：$e');
    }
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

  /// AppBar 上的胶囊按钮（带文字的图标按钮）
  Widget _buildAppBarCapsule({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    final bg = filled ? AppColors.primary : AppColors.primaryContainer;
    final fg = filled ? Colors.white : AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: const Text('作业详情'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        // 返回按钮与系统返回键走同一套逻辑
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: '返回',
          onPressed: _handleBack,
        ),
        actions: <Widget>[
          _buildAppBarCapsule(
            label: '保存全部',
            icon: Icons.bookmark_add_outlined,
            onTap: _importCoursesFromCurrentPage,
          ),
          const SizedBox(width: 8),
          _buildAppBarCapsule(
            label: '提取作业',
            icon: Icons.playlist_add_check_rounded,
            onTap: _extractTasksFromCurrentPage,
            filled: true,
          ),
          const SizedBox(width: 12),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: SizedBox(
            height: 1,
            width: double.infinity,
            child: ColoredBox(color: AppColors.border),
          ),
        ),
      ),
      // WebView 与悬浮面板平铺叠放：面板只是浮在上面的一层，
      // 不像模态弹窗那样接管整屏，网页本身随时可以点、可以输入。
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.workUrl)),
              // 刻意不给 WebView 挂任何「文档启动即执行」的脚本：页面加载阶段零注入、零采集
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                // 仅用于保持桌面版页面布局，不用于绕过风控
                // （不改请求头、不带任何伪造字段，纯 UA 字符串）
                userAgent: _desktopUA,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                // 本页只用于「显示 + 用户点击后只读提取」：
                // 不允许读本地文件，也不允许 file:// 页面跨源访问任何资源。
                allowFileAccess: false,
                allowContentAccess: false,
                allowFileAccessFromFileURLs: false,
                allowUniversalAccessFromFileURLs: false,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                // 唯一的桥：提取脚本回传题目文字（脚本只在用户点击时注入）
                controller.addJavaScriptHandler(
                  handlerName: 'onQuestionsExtracted',
                  callback: _handleQuestionsExtracted,
                );
              },
              onLoadStop: (controller, url) async {
                _currentPageUrl = url?.toString();
                _dropStaleAnswers(_currentPageUrl);
                _log('页面加载完成，正在探测题目节点...');
                _startDomProbeTimer();
                _syncCanGoBack();
              },
              onUpdateVisitedHistory: (controller, url, isReload) {
                // SPA 站内跳转不一定触发 onLoadStop，这里同步一次当前地址
                _currentPageUrl = url?.toString();
                _syncCanGoBack();
              },
              // 不接管网页弹窗：交还给网页自己显示（绝对不干预页面行为）
            ),
          ),
          // 可拖拽 / 可最小化 / 支持一键复制的悬浮面板
          Positioned.fill(
            child: AnswerFloatPanel(
              controller: _progressController,
              answers: _answers,
              enabled: _isDomReady,
              onStartPressed: () => _startAiReading(
                enabledTypes: const ['single', 'multiple', 'judge', 'fill'],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户点击后读到的一批结构化字段（一次性，用完即弃）。
///
/// **字段只有四个**：域名、页面标题、课程名提示、行数据。
/// 没有 HTML、没有隐藏域、没有 Cookie、没有页面内部 id 列表——
/// 上一版把节点 `outerHTML` 传回 Dart 的做法已经彻底移除。
class _PageRows {
  const _PageRows({
    required this.host,
    required this.pageTitle,
    required this.courseName,
    required this.rows,
  });

  /// 脱敏后的域名，只用于日志
  final String host;

  /// document.title（≤120 字）
  final String pageTitle;

  /// 页面上读到的课程名（≤40 字，可能为空）
  final String courseName;

  /// 作业行 / 课程卡片，字段由 `assets/js/page_reader.js` 白名单决定
  final List<Map<String, dynamic>> rows;
}
