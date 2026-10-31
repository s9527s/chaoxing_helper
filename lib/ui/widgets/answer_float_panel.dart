import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

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

/// 非模态悬浮答案面板（毛玻璃 + 题号遥控器）。
///
/// 与它替换掉的底部弹窗的区别：
///  - **非模态**：它只是 WebView 上面的一层，不拦截整屏、不弹路由，
///    网页本身照样可以点、可以输入；
///  - **可拖拽**：顶部灰条上下拖改变面板高度，最小化后的小球也能上下拖；
///  - **可最小化**：收成屏幕边缘的小球，点一下再展开；
///  - **题号遥控器**：一排横向滚动的题号胶囊，点哪个看哪个；
///  - **日志折叠**：默认只显示状态胶囊，点它才展开运行日志。
class AnswerFloatPanel extends StatefulWidget {
  const AnswerFloatPanel({
    super.key,
    required this.controller,
    required this.answers,
    required this.onStartPressed,
    this.enabled = true,
  });

  final SolvingProgressController controller;

  /// 当前要展示的参考答案；为空时面板只显示引导与操作按钮
  final List<AnswerEntry> answers;

  final VoidCallback onStartPressed;

  /// 页面还没探测到题目节点时，禁用「开始分析」
  final bool enabled;

  @override
  State<AnswerFloatPanel> createState() => _AnswerFloatPanelState();
}

class _AnswerFloatPanelState extends State<AnswerFloatPanel> {
  static const double _handleHeight = 22;
  static const double _headerHeight = 48;

  /// 面板最矮高度：把手(22) + 标题栏(48) + 题号栏(32+8) + 答案卡头(40) + 正文
  static const double _minPanelHeight = 280;
  static const double _ballSize = 54;

  /// 面板外边距（底部留 12，左右各 12）
  static const EdgeInsets _panelMargin = EdgeInsets.fromLTRB(12, 0, 12, 12);

  bool _minimized = false;
  double? _height;
  double? _ballTop;
  double _maxHeight = 640;

  /// 当前选中的题号（`AnswerEntry.index`）。null = 默认第一题
  int? _selectedIndex;

  /// 折叠的运行日志
  bool _showLogs = false;

  /// 刚刚复制成功的题号（1.6s 后自动回到「复制」）
  int? _copiedIndex;
  Timer? _copyResetTimer;

  @override
  void didUpdateWidget(covariant AnswerFloatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 新答案到达：展开到「看答案」的高度，并回到第 1 题
    if (widget.answers.isNotEmpty &&
        !identical(widget.answers, oldWidget.answers)) {
      _minimized = false;
      _height = null;
      _selectedIndex = null;
      _copiedIndex = null;
    }
    // 清空答案（换作业了）时收回「待提取」高度
    if (widget.answers.isEmpty && oldWidget.answers.isNotEmpty) {
      _height = null;
      _selectedIndex = null;
      _copiedIndex = null;
    }
    // 选中的题不在这批答案里了（重新分析后题目变了）→ 回到第一题
    if (_selectedIndex != null &&
        !widget.answers.any((e) => e.index == _selectedIndex)) {
      _selectedIndex = null;
    }
  }

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  /// 没有答案时占三成屏幕（别压住作业列表），有答案时铺开到一半多一点
  double get _defaultHeight {
    final ratio = widget.answers.isEmpty ? 0.32 : 0.55;
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
    // 面板要跟着 controller 的阶段/日志刷新（状态胶囊、按钮文案、日志层）
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          _maxHeight = constraints.maxHeight;
          return Stack(
            children: <Widget>[if (_minimized) _buildBall() else _buildPanel()],
          );
        },
      ),
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
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(_ballSize / 2),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x404F46E5),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  // ---------------- 展开面板 ----------------

  Widget _buildPanel() {
    final busy = widget.controller.isBusy;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Padding(
        padding: _panelMargin,
        child: AnimatedContainer(
          key: const ValueKey<String>('panel'),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          height: _currentHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.panel),
            border: Border.all(
              color: busy ? AppColors.glow : AppColors.border,
              width: 1.5,
            ),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x1A0F172A),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          // 毛玻璃：先裁圆角，再模糊背后的网页
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.panel - 1.5),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: Colors.white.withValues(alpha: 0.88),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildHandle(),
                    _buildHeader(),
                    if (_showLogs) _buildLogOverlay(),
                    Expanded(child: _buildBody()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部拖拽灰条
  Widget _buildHandle() {
    return GestureDetector(
      key: const ValueKey<String>('panel-handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        setState(() {
          _height = _clampHeight(_currentHeight - details.delta.dy);
        });
      },
      child: SizedBox(
        height: _handleHeight,
        child: Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  /// 标题 + 状态胶囊 + 重新分析 + 最小化
  Widget _buildHeader() {
    return SizedBox(
      height: _headerHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
        child: Row(
          children: <Widget>[
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.auto_awesome,
                size: 15,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 8),
            const Flexible(
              child: Text(
                'AI 阅读助手',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildStatusPill(),
            const Spacer(),
            _buildActionCapsule(),
            const SizedBox(width: 2),
            IconButton(
              key: const ValueKey<String>('panel-minimize'),
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: AppColors.secondary,
              ),
              tooltip: '最小化',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _minimized = true),
            ),
          ],
        ),
      ),
    );
  }

  /// 状态胶囊：绿点「已就绪」/ 转圈「分析中」，点开才看日志
  Widget _buildStatusPill() {
    final stage = widget.controller.stage;
    final busy = widget.controller.isBusy;

    final Color color;
    final String label;
    switch (stage) {
      case SolvingStage.idle:
        color = AppColors.muted;
        label = '待开始';
      case SolvingStage.extracting:
      case SolvingStage.thinking:
        color = AppColors.primary;
        label = '分析中';
      case SolvingStage.completed:
        color = AppColors.success;
        label = '已就绪';
      case SolvingStage.error:
        color = AppColors.danger;
        label = '分析失败';
    }

    return GestureDetector(
      key: const ValueKey<String>('status-pill'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showLogs = !_showLogs),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy)
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: color,
                ),
              )
            else
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.2,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              _showLogs
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 13,
              color: color,
            ),
          ],
        ),
      ),
    );
  }

  /// 「开始分析 / 重新分析 / 重试」胶囊
  Widget _buildActionCapsule() {
    final stage = widget.controller.stage;
    final busy = widget.controller.isBusy;
    final disabled = busy || (!widget.enabled && stage == SolvingStage.idle);

    final String label;
    switch (stage) {
      case SolvingStage.idle:
        label = widget.enabled ? '开始分析' : '先打开作业';
      case SolvingStage.extracting:
      case SolvingStage.thinking:
        label = '执行中';
      case SolvingStage.completed:
        label = '重新分析';
      case SolvingStage.error:
        label = '重试';
    }

    return SizedBox(
      height: 32,
      child: FilledButton(
        onPressed: disabled ? null : widget.onStartPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primaryContainer,
          foregroundColor: AppColors.primary,
          disabledBackgroundColor: AppColors.fill,
          disabledForegroundColor: AppColors.muted,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// 折叠日志层（点状态胶囊展开）
  Widget _buildLogOverlay() {
    final logs = widget.controller.logs;

    return Container(
      constraints: const BoxConstraints(maxHeight: 148),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: logs.isEmpty
          ? const Text(
              '暂无运行日志',
              style: TextStyle(fontSize: 11.5, color: AppColors.muted),
            )
          : ListView.builder(
              key: const ValueKey<String>('log-list'),
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: logs.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  logs[index],
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: AppColors.secondary,
                  ),
                ),
              ),
            ),
    );
  }

  // ---------------- 主体 ----------------

  Widget _buildBody() {
    final entry = _selectedEntry;
    if (entry == null) return _buildEmptyHint();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildIndexBar(entry.index),
          const SizedBox(height: 10),
          Expanded(
            // 切题时淡入淡出
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _buildDetail(entry, key: ValueKey<int>(entry.index)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyHint() {
    final message = widget.enabled
        ? '点右上角「开始分析」：读取本页题目 → 请求 AI →\n用题号逐个对照答案自己作答。本工具不会替你填写。'
        : '当前页没有题目 · 请先打开某次作业，\n等题目加载出来再点「开始分析」。';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                widget.enabled
                    ? Icons.auto_awesome_outlined
                    : Icons.menu_book_rounded,
                size: 22,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: AppColors.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 题号胶囊（遥控器） ----------------

  Widget _buildIndexBar(int selectedIndex) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        key: const ValueKey<String>('index-bar'),
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: widget.answers.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = widget.answers[index];
          final selected = entry.index == selectedIndex;
          return GestureDetector(
            key: ValueKey<String>('index-chip-${entry.index}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              _selectedIndex = entry.index;
              _copiedIndex = null;
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              height: 32,
              constraints: const BoxConstraints(minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? AppColors.primary : AppColors.fill,
                borderRadius: BorderRadius.circular(16),
                boxShadow: selected
                    ? const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x334F46E5),
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                '${entry.index}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.secondary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------- 单题详情 ----------------

  Widget _buildDetail(AnswerEntry entry, {Key? key}) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '第 ${entry.index} 题',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(width: 8),
              _buildTypePill(entry.typeLabel),
              const Spacer(),
              _buildCopyAllIcon(),
              const SizedBox(width: 6),
              _buildCopyCapsule(entry),
            ],
          ),
          if (_shouldShowStem(entry)) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              entry.stem,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: AppColors.secondary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              key: const ValueKey<String>('answer-detail'),
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Text(
                  entry.answer,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.6,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ),
          ),
        ],
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
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
          color: AppColors.primary,
        ),
      ),
    );
  }

  /// 一键复制全部（图标，放在「复制」左边）
  Widget _buildCopyAllIcon() {
    if (widget.answers.length <= 1) return const SizedBox.shrink();
    return Tooltip(
      message: '复制全部 ${widget.answers.length} 条',
      child: GestureDetector(
        key: const ValueKey<String>('copy-all'),
        behavior: HitTestBehavior.opaque,
        onTap: _copyAll,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.fill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.copy_all_outlined,
            size: 15,
            color: AppColors.secondary,
          ),
        ),
      ),
    );
  }

  /// 一键复制胶囊：点完变绿色「已复制」
  Widget _buildCopyCapsule(AnswerEntry entry) {
    final copied = _copiedIndex == entry.index;

    return GestureDetector(
      key: ValueKey<String>('copy-${entry.index}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _copyEntry(entry),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: copied ? const Color(0xFFDCFCE7) : AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: copied ? const Color(0xFFBBF7D0) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              copied ? Icons.check_rounded : Icons.content_copy_rounded,
              size: 13,
              color: copied ? AppColors.success : AppColors.primary,
            ),
            const SizedBox(width: 4),
            Text(
              copied ? '已复制' : '复制',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: copied ? AppColors.success : AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 复制 ----------------

  Future<void> _copyEntry(AnswerEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.answer));
    await HapticFeedback.lightImpact();
    if (!mounted) return;

    setState(() => _copiedIndex = entry.index);
    // 1.6s 后回到「复制」，期间再次点击会刷新计时
    _copyResetTimer?.cancel();
    _copyResetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _copiedIndex = null);
    });
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
          margin: EdgeInsets.fromLTRB(16, 8, 16, _currentHeight + 30),
        ),
      );
  }
}
