import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum SolvingStage { idle, extracting, thinking, completed, error }

class SolvingProgressController extends ChangeNotifier {
  SolvingStage stage = SolvingStage.idle;
  int totalCount = 0;
  int solvableCount = 0;
  int currentImageIndex = 0;
  int totalImages = 0;
  String? errorMessage;
  final List<String> logs = [];

  void setStage(SolvingStage newStage, {String? logMessage}) {
    stage = newStage;
    if (logMessage != null) addLog(logMessage);
    notifyListeners();
  }

  void updateQuestionStats(int total, int solvable) {
    totalCount = total;
    solvableCount = solvable;
    notifyListeners();
  }

  void updateImageProgress(int current, int total) {
    currentImageIndex = current;
    totalImages = total;
    notifyListeners();
  }

  void setError(String message) {
    errorMessage = message;
    stage = SolvingStage.error;
    addLog('❌ 错误: $message');
  }

  /// 额外日志出口（页面用它把日志同时打到 logcat）
  void Function(String message)? logSink;

  void addLog(String message) {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    logs.insert(0, '[$timeStr] $message');
    logSink?.call(message);
    notifyListeners();
  }

  void reset() {
    stage = SolvingStage.idle;
    currentImageIndex = 0;
    totalImages = 0;
    errorMessage = null;
    logs.clear();
    notifyListeners();
  }

  bool get isBusy =>
      stage == SolvingStage.extracting || stage == SolvingStage.thinking;
}

/// 一条参考答案（悬浮面板渲染 + 一键复制的最小单元）
class AnswerEntry {
  const AnswerEntry({
    required this.index,
    required this.typeLabel,
    required this.answer,
    this.stem = '',
  });

  final int index;
  final String typeLabel;
  final String answer;

  /// 题干，只作两行预览，复制时不包含
  final String stem;

  /// 复制全部时的文本片段
  String get dumpText => '第 $index 题 · $typeLabel\n$answer';
}

/// 非模态悬浮答案面板。
///
/// 与它替换掉的底部弹窗的区别：
///  - **非模态**：它只是 WebView 上面的一层，不拦截整屏、不弹路由，
///    网页本身照样可以点、可以输入；
///  - **可拖拽**：顶部把手上下拖改变面板高度，最小化后的小球也能上下拖；
///  - **可最小化**：收成屏幕边缘的小球，点一下再展开；
///  - **一键复制**：每条答案右侧有复制按钮，标题栏有「复制全部」。
class AnswerFloatPanel extends StatefulWidget {
  const AnswerFloatPanel({
    super.key,
    required this.controller,
    required this.answers,
    required this.onStartPressed,
    this.enabled = true,
  });

  final SolvingProgressController controller;

  /// 当前要展示的参考答案；为空时面板只显示日志与控制按钮
  final List<AnswerEntry> answers;

  final VoidCallback onStartPressed;

  /// 页面还没探测到题目节点时，禁用「提取」按钮
  final bool enabled;

  @override
  State<AnswerFloatPanel> createState() => _AnswerFloatPanelState();
}

class _AnswerFloatPanelState extends State<AnswerFloatPanel> {
  static const double _handleHeight = 22;
  static const double _headerHeight = 44;
  static const double _minPanelHeight = 200;
  static const double _ballSize = 54;
  static const Color _ink = Color(0xFF1B1B1F);

  bool _minimized = false;
  double? _height;
  double? _ballTop;
  double _maxHeight = 640;

  @override
  void didUpdateWidget(covariant AnswerFloatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新答案到达时自动展开到「看答案」的高度，免得用户以为没生成
    if (widget.answers.isNotEmpty &&
        !identical(widget.answers, oldWidget.answers)) {
      _minimized = false;
      _height = null;
    }
    // 清空答案（换作业了）时收回「待提取」高度
    if (widget.answers.isEmpty && oldWidget.answers.isNotEmpty) {
      _height = null;
    }
  }

  /// 没有答案时只占三成屏幕（别压住作业列表），有答案时才铺开到四成半
  double get _defaultHeight {
    final ratio = widget.answers.isEmpty ? 0.30 : 0.45;
    return _maxHeight * ratio;
  }

  double _clampHeight(double value) {
    final upper = _maxHeight - 110;
    if (upper <= _minPanelHeight) return _minPanelHeight;
    return value.clamp(_minPanelHeight, upper);
  }

  double get _currentHeight => _clampHeight(_height ?? _defaultHeight);

  double _clampBallTop(double value) {
    final upper = _maxHeight - _ballSize - 30;
    if (upper <= 90) return 90;
    return value.clamp(90, upper);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maxHeight = constraints.maxHeight;
        return Stack(
          children: <Widget>[
            if (_minimized) _buildBall() else _buildPanel(),
          ],
        );
      },
    );
  }

  // ---------------- 最小化后的小球 ----------------

  Widget _buildBall() {
    final top = _clampBallTop(_ballTop ?? _maxHeight * 0.5);

    return Positioned(
      key: const ValueKey<String>('panel-ball'),
      top: top,
      right: 10,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _minimized = false),
        onVerticalDragUpdate: (details) {
          setState(() {
            _ballTop = _clampBallTop(top + details.delta.dy);
          });
        },
        child: Container(
          width: _ballSize,
          height: _ballSize,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(_ballSize / 2),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 23),
        ),
      ),
    );
  }

  // ---------------- 展开面板 ----------------

  Widget _buildPanel() {
    return Positioned(
      key: const ValueKey<String>('panel'),
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.white,
        elevation: 14,
        shadowColor: const Color(0x33000000),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: _currentHeight,
          child: Column(
            children: <Widget>[
              _buildHandle(),
              _buildHeader(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  /// 上下拖动把手改变面板高度（往上拖变高）
  Widget _buildHandle() {
    return GestureDetector(
      key: const ValueKey<String>('panel-handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        setState(() {
          _height = _clampHeight(_currentHeight - details.delta.dy);
        });
      },
      child: const SizedBox(
        height: _handleHeight,
        child: Center(
          child: SizedBox(
            width: 46,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0x2E000000),
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final hasAnswers = widget.answers.isNotEmpty;

    return SizedBox(
      height: _headerHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: <Widget>[
            const Icon(Icons.auto_awesome_outlined, size: 16, color: _ink),
            const SizedBox(width: 6),
            Text(
              hasAnswers
                  ? '参考答案 ${widget.answers.length} 条'
                  : 'AI 阅读助手',
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            ),
            const Spacer(),
            if (hasAnswers)
              IconButton(
                icon: const Icon(Icons.copy_all_outlined, size: 20),
                tooltip: '复制全部',
                onPressed: _copyAll,
              ),
            IconButton(
              icon: const Icon(Icons.minimize, size: 20),
              tooltip: '最小化',
              onPressed: () => setState(() => _minimized = true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        return Column(
          children: <Widget>[
            Expanded(
              child: widget.answers.isEmpty
                  ? _buildLogList()
                  : _buildAnswerList(),
            ),
            _buildFooter(),
          ],
        );
      },
    );
  }

  Widget _buildAnswerList() {
    return ListView.separated(
      key: const ValueKey<String>('answer-list'),
      padding: const EdgeInsets.fromLTRB(12, 2, 6, 6),
      itemCount: widget.answers.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildAnswerCard(widget.answers[index]),
    );
  }

  Widget _buildAnswerCard(AnswerEntry entry) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x0F000000)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${entry.index}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '第 ${entry.index} 题 · ${entry.typeLabel}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  entry.answer,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
                if (entry.stem.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 5),
                  Text(
                    entry.stem,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: Color(0x6B000000),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.content_copy_outlined, size: 19),
            tooltip: '复制这条答案',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            onPressed: () => _copy(entry.answer),
          ),
        ],
      ),
    );
  }

  Widget _buildLogList() {
    final logs = widget.controller.logs;

    if (logs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            '点下面的按钮：读取页面题目 → 请求 AI → 在面板里对照答案手动作答。\n'
            '本工具不会替你填写任何内容。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.6, color: Color(0x8A000000)),
          ),
        ),
      );
    }

    return ListView.builder(
      key: const ValueKey<String>('log-list'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      itemCount: logs.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          logs[index],
          style: const TextStyle(fontSize: 12, height: 1.45, color: Color(0x8A000000)),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final controller = widget.controller;
    final latest = controller.logs.isEmpty
        ? '准备就绪（未开始）'
        : controller.logs.first;

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x0F000000))),
      ),
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: Text(
              latest,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Color(0x8A000000)),
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: FilledButton(
              onPressed: controller.isBusy || !widget.enabled
                  ? null
                  : widget.onStartPressed,
              style: FilledButton.styleFrom(
                backgroundColor: controller.stage == SolvingStage.error
                    ? const Color(0xFFD32F2F)
                    : _ink,
                disabledBackgroundColor: const Color(0x1F000000),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                _buttonLabel(controller.stage),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buttonLabel(SolvingStage stage) {
    // 页面上没有题目节点时，按钮是灰的；这时把原因写在按钮上，
    // 否则用户只会看到「提取题目并请求 AI」却点不动，不知道先去作业列表页。
    if (!widget.enabled && stage == SolvingStage.idle) {
      return '当前页没有题目 · 请先打开某次作业';
    }
    switch (stage) {
      case SolvingStage.idle:
        return '提取题目并请求 AI';
      case SolvingStage.extracting:
      case SolvingStage.thinking:
        return '执行中...';
      case SolvingStage.completed:
        return '重新分析';
      case SolvingStage.error:
        return '重试';
    }
  }

  // ---------------- 复制 ----------------

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack('已复制');
  }

  Future<void> _copyAll() async {
    final text = widget.answers.map((e) => e.dumpText).join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack('已复制全部 ${widget.answers.length} 条');
  }

  void _snack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          // 浮在面板上方，别被自己的面板挡住
          margin: EdgeInsets.fromLTRB(16, 8, 16, _currentHeight + 20),
        ),
      );
  }
}
