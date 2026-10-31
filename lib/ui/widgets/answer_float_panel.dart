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

  /// 题干，只作预览，复制时不包含
  final String stem;

  /// 复制全部时的文本片段
  String get dumpText => '第 $index 题 · $typeLabel\n$answer';
}

/// 非模态悬浮答案面板（Material 3 卡片风格）。
///
/// 与它替换掉的底部弹窗的区别：
///  - **非模态**：它只是 WebView 上面的一层，不拦截整屏、不弹路由，
///    网页本身照样可以点、可以输入；
///  - **可拖拽**：顶部把手上下拖改变面板高度，最小化后的小球也能上下拖；
///  - **可最小化**：收成屏幕边缘的小球，点一下再展开；
///  - **题号遥控器**：顶部一排题号按钮 `[1] [2] [3]…`，点哪个看哪个，
///    按钮高亮，下方卡片只渲染这一题的答案（长作文也不会撑爆面板）；
///  - **一键复制**：详情卡右上角「复制」，顶栏有「复制全部」。
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
  static const double _headerHeight = 46;
  /// 面板最矮高度：要同时容下把手(22) + 标题栏(46) + 题号区(≈45) +
  /// 答案卡标题行(≈51) + 底部操作区(≈86)，再留一点正文空间。
  /// 低于这个值答案卡就会被挤爆（RenderFlex overflow），所以直接兜底。
  static const double _minPanelHeight = 300;
  static const double _ballSize = 54;

  /// 题号按钮：38 见方，间距 7 —— 400 宽的面板一行正好 8 个
  static const double _chipSize = 38;
  static const double _chipGap = 7;

  /// 题号区最多两行，再多就纵向滚动，别把答案区挤没
  static const double _indexBarMaxHeight = _chipSize * 2 + _chipGap + 4;

  // M3 配色：主色蓝紫渐变，卡片纯白，底色浅灰
  static const Color _primary = Color(0xFF3D5AFE);
  static const Color _accent = Color(0xFF7C4DFF);
  static const Color _ink = Color(0xFF1B1B1F);
  static const Color _surface = Color(0xFFF6F7FB);

  bool _minimized = false;
  double? _height;
  double? _ballTop;
  double _maxHeight = 640;

  /// 当前选中的题号（`AnswerEntry.index`）。null = 默认第一题
  int? _selectedIndex;

  @override
  void didUpdateWidget(covariant AnswerFloatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 新答案到达：展开到「看答案」的高度，并回到第 1 题
    if (widget.answers.isNotEmpty &&
        !identical(widget.answers, oldWidget.answers)) {
      _minimized = false;
      _height = null;
      _selectedIndex = null;
    }
    // 清空答案（换作业了）时收回「待提取」高度
    if (widget.answers.isEmpty && oldWidget.answers.isNotEmpty) {
      _height = null;
      _selectedIndex = null;
    }
    // 选中的题不在这批答案里了（重新分析后题目变了）→ 回到第一题
    if (_selectedIndex != null &&
        !widget.answers.any((e) => e.index == _selectedIndex)) {
      _selectedIndex = null;
    }
  }

  /// 没有答案时只占三成屏幕（别压住作业列表），有答案时才铺开到一半
  /// （题号栏占掉约 45 的高度，所以比只有列表时多给一点）
  double get _defaultHeight {
    final ratio = widget.answers.isEmpty ? 0.30 : 0.50;
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

  /// 当前该显示哪一题：选中项优先，否则第一题
  AnswerEntry? get _selectedEntry {
    if (widget.answers.isEmpty) return null;
    final index = _selectedIndex;
    if (index != null) {
      for (final entry in widget.answers) {
        if (entry.index == index) return entry;
      }
    }
    return widget.answers.first;
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
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[_primary, _accent],
            ),
            borderRadius: BorderRadius.circular(_ballSize / 2),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x463D5AFE),
                blurRadius: 16,
                offset: Offset(0, 6),
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
        color: _surface,
        elevation: 18,
        shadowColor: const Color(0x4D1B1B1F),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: _currentHeight,
          child: Column(
            children: <Widget>[
              _buildTopBar(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  /// 把手 + 标题栏 + 题号栏，共用一层主题色渐变底
  Widget _buildTopBar() {
    final selected = _selectedEntry;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            _primary.withValues(alpha: 0.12),
            _accent.withValues(alpha: 0.05),
          ],
        ),
      ),
      child: Column(
        // 拉伸：题号栏要占满整行并左对齐，不然 Wrap 会按内容宽度居中
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHandle(),
          _buildHeader(),
          if (selected != null) ...<Widget>[
            _buildIndexBar(selected.index),
            const _TopBarTail(),
          ],
        ],
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
                color: Color(0x33000000),
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
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: <Widget>[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[_primary, _accent],
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x333D5AFE),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.auto_awesome,
                size: 16,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                hasAnswers ? '参考答案 ${widget.answers.length} 条' : 'AI 阅读助手',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  color: _ink,
                ),
              ),
            ),
            const Spacer(),
            if (hasAnswers)
              IconButton(
                icon: const Icon(Icons.copy_all_outlined, size: 20),
                tooltip: '复制全部',
                visualDensity: VisualDensity.compact,
                onPressed: _copyAll,
              ),
            IconButton(
              icon: const Icon(Icons.minimize, size: 20),
              tooltip: '最小化',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _minimized = true),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 题号栏（遥控器） ----------------

  /// 横向排布的题号按钮：点哪个高亮哪个，下方卡片立刻切成那一题
  Widget _buildIndexBar(int selectedIndex) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _indexBarMaxHeight),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Wrap(
          key: const ValueKey<String>('index-bar'),
          spacing: _chipGap,
          runSpacing: _chipGap,
          children: <Widget>[
            for (final entry in widget.answers)
              _buildIndexChip(entry, selected: entry.index == selectedIndex),
          ],
        ),
      ),
    );
  }

  Widget _buildIndexChip(AnswerEntry entry, {required bool selected}) {
    return GestureDetector(
      key: ValueKey<String>('index-chip-${entry.index}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selectedIndex = entry.index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: _chipSize,
        height: _chipSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[_primary, _accent],
                )
              : null,
          color: selected ? null : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? null
              : Border.all(color: const Color(0x1A000000), width: 1),
          boxShadow: selected
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x4D3D5AFE),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ]
              : const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x0A1B1B1F),
                    blurRadius: 5,
                    offset: Offset(0, 2),
                  ),
                ],
        ),
        child: Text(
          '${entry.index}',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : _ink,
          ),
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
              child: _selectedEntry == null
                  ? _buildLogList()
                  : _buildAnswerDetail(_selectedEntry!),
            ),
            _buildFooter(),
          ],
        );
      },
    );
  }

  // ---------------- 单题详情卡 ----------------

  Widget _buildAnswerDetail(AnswerEntry entry) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Container(
        key: const ValueKey<String>('answer-detail'),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x11000000)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x121B1B1F),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
              child: Row(
                children: <Widget>[
                  _buildIndexBadge(entry.index),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      '第 ${entry.index} 题',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildTypePill(entry.typeLabel),
                  const Spacer(),
                  _buildCopyButton(entry.answer),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0x0F000000)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_shouldShowStem(entry)) ...<Widget>[
                      Text(
                        entry.stem,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Color(0x99000000),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Text(
                      entry.answer,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.55,
                        color: Color(0xE61B1B1F),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 题干要不要显示。
  ///
  /// AI 有时会把题干原样抄进答案开头（尤其是翻译/简答题），这时再单独显示
  /// 一遍题干，卡片顶部就成了一模一样的两段字，看着像重复渲染。
  bool _shouldShowStem(AnswerEntry entry) {
    final stem = entry.stem.replaceAll(RegExp(r'\s+'), '');
    if (stem.isEmpty) return false;
    final answer = entry.answer.replaceAll(RegExp(r'\s+'), '');
    final probe = stem.length > 24 ? stem.substring(0, 24) : stem;
    return !answer.contains(probe);
  }

  Widget _buildTypePill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _accent,
        ),
      ),
    );
  }

  // ---------------- 共用小部件 ----------------

  Widget _buildIndexBadge(int index) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$index',
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: _primary,
        ),
      ),
    );
  }

  Widget _buildCopyButton(String text) {
    return TextButton.icon(
      onPressed: () => _copy(text),
      icon: const Icon(Icons.content_copy_rounded, size: 15),
      label: const Text('复制'),
      style: TextButton.styleFrom(
        foregroundColor: _primary,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
            '点下面的按钮：读取页面题目 → 请求 AI → 用顶部题号逐个对照答案手动作答。\n'
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
          style: const TextStyle(
            fontSize: 12,
            height: 1.45,
            color: Color(0x8A000000),
          ),
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
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0x0F000000))),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
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
            height: 44,
            child: FilledButton(
              onPressed:
                  controller.isBusy || !widget.enabled
                      ? null
                      : widget.onStartPressed,
              style: FilledButton.styleFrom(
                backgroundColor:
                    controller.stage == SolvingStage.error
                        ? const Color(0xFFD32F2F)
                        : _primary,
                disabledBackgroundColor: const Color(0x1F000000),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(
                _buttonLabel(controller.stage),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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

/// 题号栏与下方卡片之间的淡淡分隔（吸收渐变到纯色底的过渡）
class _TopBarTail extends StatelessWidget {
  const _TopBarTail();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: const Color(0x0F000000));
  }
}
