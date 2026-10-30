import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/network/cookie_sync_helper.dart';
import '../../data/services/scanner_service.dart';
import 'login_page.dart';
import 'work_webview_page.dart';

// ============================================================
// 数据模型
// ============================================================

/// 任务类型：highRisk = true 的一律禁止进内置 WebView，只能外部浏览器打开。
enum TaskType {
  homework('标准作业', false, Icons.assignment_outlined),
  paper('论文', true, Icons.article_outlined),
  exam('考试', true, Icons.timer_outlined),
  video('视频实践', true, Icons.play_circle_outlined),
  experiment('实验论文', true, Icons.science_outlined);

  const TaskType(this.label, this.highRisk, this.icon);

  final String label;
  final bool highRisk;
  final IconData icon;
}

/// 看板上的一条任务（由 HomeworkItem 映射而来）
class CourseTask {
  const CourseTask({
    required this.title,
    required this.courseName,
    required this.type,
    required this.deadline,
    required this.url,
    this.deadlineUnknown = false,
    this.identity,
  });

  final String title;
  final String courseName;
  final TaskType type;
  final DateTime deadline;
  final String url;

  /// 页面没有给出截止时间（排序用 deadline 占位，UI 显示「待定」）
  final bool deadlineUnknown;

  /// 稳定唯一标识（workId），用于跨次导入去重
  final String? identity;

  bool get highRisk => type.highRisk;

  bool get isExpired => !deadline.isAfter(DateTime.now());

  int get hoursLeft => deadline.difference(DateTime.now()).inMinutes ~/ 60;

  bool get isUrgent => !isExpired && hoursLeft < 24;
}

/// 课程分组
class CourseGroup {
  const CourseGroup({
    required this.name,
    required this.teacher,
    required this.tasks,
    required this.accent,
  });

  final String name;
  final String teacher;
  final List<CourseTask> tasks;
  final Color accent;

  int get taskCount => tasks.length;

  int get highRiskCount => tasks.where((t) => t.highRisk).length;

  bool get hasTasks => tasks.isNotEmpty;

  /// 最近的一个截止时间
  CourseTask? get nearest {
    if (tasks.isEmpty) return null;
    final sorted = List<CourseTask>.of(tasks)
      ..sort((a, b) => a.deadline.compareTo(b.deadline));
    return sorted.first;
  }
}

/// 视图模式
enum DashboardView { byCourse, byTask }

// ============================================================
// 页面
// ============================================================

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, this.debugCourses});

  /// 仅用于测试/本地预览：传入后直接渲染这批数据，跳过「空状态」。
  /// 生产环境保持 null，数据来自「手动进页面提取」。
  final List<CourseGroup>? debugCourses;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // ---- 视觉常量 ----
  static const Color _urgentColor = Color(0xFFE53935);
  static const Color _safeColor = Color(0xFF2E7D32);
  static const Color _expiredColor = Color(0xFF9E9E9E);
  static const Color _riskColor = Color(0xFFB26A00);
  static const Color _riskBg = Color(0xFFFFF4E0);
  static const Color _safeBg = Color(0xFFE8F5E9);
  static const Color _pageBg = Color(0xFFF6F7F9);

  DashboardView _view = DashboardView.byCourse;
  List<CourseGroup> _courses = <CourseGroup>[];

  /// 课程色板，按出现顺序循环取色
  static const List<Color> _coursePalette = <Color>[
    Color(0xFF3F6BE0),
    Color(0xFF7C4DFF),
    Color(0xFF26A69A),
    Color(0xFFEF6C00),
    Color(0xFFD81B60),
    Color(0xFF546E7A),
    Color(0xFF00897B),
  ];

  @override
  void initState() {
    super.initState();
    // 刻意不再自动扫描：
    // 自动扫描只会白跑半分钟然后返回 0 条。数据来源统一改为「手动进页面提取」。
    final injected = widget.debugCourses;
    if (injected != null) {
      _courses = injected;
    }
  }

  // ---------------- 数据 ----------------

  /// 本地测试页地址（走 adb reverse 把电脑的 8899 转发到手机 127.0.0.1）
  static const String _debugDefaultUrl = 'http://127.0.0.1:8899/index.html';

  /// 调试用（仅 kDebugMode 可见）：在内置 WebView 打开任意 URL，
  /// 配合仓库里的 mock_work/ 本地模拟作业页做端到端测试。
  Future<void> _openDebugUrlDialog() async {
    var input = _debugDefaultUrl;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('打开测试页'),
        content: TextFormField(
          initialValue: _debugDefaultUrl,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          onChanged: (value) => input = value,
          decoration: const InputDecoration(
            labelText: 'URL',
            hintText: 'http://127.0.0.1:8899/index.html',
            helperText: '需先执行 adb reverse tcp:8899 tcp:8899',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('打开'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final target = input.trim().isEmpty ? _debugDefaultUrl : input.trim();
    await Navigator.of(context).push<List<HomeworkItem>>(
      MaterialPageRoute<List<HomeworkItem>>(
        builder: (_) => WorkWebViewPage(workTitle: '本地测试页', workUrl: target),
      ),
    );
  }

  /// 打开内置浏览器，让用户手动点到「课程 → 作业」再点右上角提取。
  /// 这是当前唯一的数据来源：页面已经由用户手动打开，绕开了动态签名问题。
  Future<void> _openManualEntry() async {
    final imported = await Navigator.of(context).push<List<HomeworkItem>>(
      MaterialPageRoute<List<HomeworkItem>>(
        builder: (_) => const WorkWebViewPage(
          workTitle: '手动进入作业页',
          workUrl: 'https://mooc1.chaoxing.com/visit/interaction',
        ),
      ),
    );
    _handleImported(imported);
  }

  /// 从标题 + 解析类型推断任务类型（决定是否上锁）
  TaskType _inferType(HomeworkItem item) {
    final title = item.title;

    if (title.contains('实验') && title.contains('论文')) return TaskType.experiment;
    if (title.contains('论文')) return TaskType.paper;
    if (title.contains('视频') || title.contains('实践')) return TaskType.video;
    if (title.contains('考试') || title.contains('测验') || title.contains('测试')) {
      return TaskType.exam;
    }
    if (title.contains('实验')) return TaskType.experiment;

    // 标题看不出来时退回解析层给的类型
    return item.kind == HomeworkKind.exam ? TaskType.exam : TaskType.homework;
  }

  /// 按作业视图用的扁平列表：紧急的在前
  List<CourseTask> get _sortedTasks {
    final all = _courses.expand((c) => c.tasks).toList();
    all.sort((a, b) => a.deadline.compareTo(b.deadline));
    return all;
  }

  int get _pendingCount => _courses.expand((c) => c.tasks).where((t) => !t.isExpired).length;

  int get _highRiskCount => _courses.expand((c) => c.tasks).where((t) => t.highRisk).length;

  String get _summaryText => '共 ${_courses.length} 门课 · $_pendingCount 份待办';

  String get _keyStatusText {
    final models = AppConfig.getLlmModels();
    if (models.isEmpty) return '模型：未配置（点右上角设置添加）';
    final usable = models.where((m) => m.hasKey).length;
    final names = models.map((m) => m.label).join(' / ');
    return '模型 $usable/${models.length}：$names';
  }

  // ---------------- 状态颜色 / 文案 ----------------

  Color _statusColor(CourseTask task) {
    if (task.isExpired) return _expiredColor;
    if (task.isUrgent) return _urgentColor;
    return _safeColor;
  }

  String _countdownLabel(CourseTask task) {
    if (task.deadlineUnknown) return '待定';
    if (task.isExpired) return '已截止';
    if (task.hoursLeft < 24) return '🔥 剩 ${task.hoursLeft}小时';
    final days = (task.hoursLeft / 24).ceil();
    return '剩 $days天';
  }

  // ---------------- 点击拦截 ----------------

  Future<void> _onTaskTap(CourseTask task) async {
    if (task.highRisk) {
      await _confirmHighRisk(task);
      return;
    }
    await _openWorkWebView(task);
  }

  /// 普通作业：进内置 WebView；页面里点「提取本页作业」可回传任务
  Future<void> _openWorkWebView(CourseTask task) async {
    if (!AppConfig.hasUsableModel) {
      _toast('尚未配置可用的模型 Key，AI 解题会失败，请先点右上角设置');
    }
    final imported = await Navigator.of(context).push<List<HomeworkItem>>(
      MaterialPageRoute<List<HomeworkItem>>(
        builder: (_) => WorkWebViewPage(
          workTitle: task.title,
          workUrl: task.url,
        ),
      ),
    );
    _handleImported(imported);
  }

  /// 接收 WorkWebViewPage 回传的作业并合并进看板
  void _handleImported(List<HomeworkItem>? items) {
    if (items == null || items.isEmpty) return;

    final byName = <String, CourseGroup>{for (final c in _courses) c.name: c};
    var added = 0;

    for (final item in items) {
      final task = CourseTask(
        title: item.title,
        courseName: item.courseName,
        type: _inferType(item),
        deadline: item.deadline ?? DateTime.now().add(const Duration(days: 30)),
        url: item.url,
        deadlineUnknown: item.deadline == null,
        identity: item.identity,
      );

      final group = byName[item.courseName];
      if (group == null) {
        final created = CourseGroup(
          name: item.courseName,
          teacher: '共 1 份任务',
          tasks: <CourseTask>[task],
          accent: _coursePalette[_courses.length % _coursePalette.length],
        );
        byName[item.courseName] = created;
        _courses.add(created);
        added++;
        continue;
      }

      // 同一 workId 视为同一份作业：多次提取（URL 签名可能变化）也不会重复堆积
      final duplicated = group.tasks.any((t) {
        if (t.identity != null && task.identity != null) {
          return t.identity == task.identity;
        }
        return t.url == task.url && t.title == task.title;
      });
      if (duplicated) continue;
      group.tasks.add(task);
      added++;
    }

    if (!mounted) return;
    setState(() {});
    _toast(added > 0 ? '已导入 $added 条作业' : '这些作业已经在看板里了');
  }

  /// 高风险任务：只允许系统外部浏览器，绝不进内置 WebView
  Future<void> _confirmHighRisk(CourseTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe_rounded, color: _riskColor),
        title: const Text('高风险任务'),
        content: Text(
          '「${task.type.label}」属于高风险场景，禁止在内置 WebView 加载。\n\n'
          '任务：${task.title}\n课程：${task.courseName}\n\n'
          '确认后将使用系统外部浏览器打开，本工具不会读取或修改页面内容。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _riskColor),
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('用外部浏览器打开'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _openInExternalBrowser(task);
  }

  Future<void> _openInExternalBrowser(CourseTask task) async {
    final uri = Uri.tryParse(task.url);
    if (uri == null) {
      _toast('链接无效，无法打开');
      return;
    }
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) _toast('未找到可打开该链接的浏览器');
    } catch (e) {
      _toast('打开外部浏览器失败：$e');
    }
  }

  /// 课程卡片点击 → 底部弹窗列出该课程待办（按截止时间倒序）
  Future<void> _showCourseTasks(CourseGroup course) async {
    if (!course.hasTasks) {
      _toast('该课程暂无待办作业');
      return;
    }

    final sorted = List<CourseTask>.of(course.tasks)
      ..sort((a, b) => b.deadline.compareTo(a.deadline)); // 倒序：最晚 → 最早

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      course.name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${course.taskCount} 份待办',
                    style: TextStyle(fontSize: 12.5, color: Colors.black.withValues(alpha: 0.45)),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () {
                      if (!sheetContext.mounted) return;
                      Navigator.of(sheetContext).pop();
                    },
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: '关闭',
                  ),
                ],
              ),
              Text(
                '按截止时间倒序排列',
                style: TextStyle(fontSize: 11.5, color: Colors.black.withValues(alpha: 0.38)),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 4),
                  itemCount: sorted.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (_, index) => _buildTaskTile(sorted[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 设置弹窗 / 退出 ----------------

  /// 设置弹窗：刻意不使用 TextEditingController（showDialog 返回时弹窗仍在做退出动画，
  /// 此时 dispose controller 会让仍挂载的 TextField 访问已释放对象）
  /// 模型设置弹窗：动态列表，每张卡片一套 名称 / BaseUrl / Model / API Key。
  ///
  /// 输入用「局部对象 + TextFormField(initialValue)」，不用 TextEditingController：
  /// showDialog 的 Future 在 pop 时立即完成，此时弹窗仍在跑退出动画，
  /// 提前 dispose controller 会让仍挂载的 TextField 访问已释放对象（曾导致白屏断言）。
  Future<void> _showKeyDialog() async {
    var nextDraftId = 0;
    final drafts = AppConfig.getLlmModels()
        .map((m) => _ModelDraft.fromModel(m, nextDraftId++))
        .toList();
    if (drafts.isEmpty) {
      drafts.add(_ModelDraft.empty(nextDraftId++));
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('模型设置'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Flexible(
                  child: drafts.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            '还没有任何模型，点下面按钮添加一个',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.black.withValues(alpha: 0.45),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: drafts.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) => _buildModelCard(
                            draft: drafts[index],
                            index: index,
                            // 首项禁用上移、末项禁用下移（onPressed 为 null 时自动置灰）
                            onMoveUp: index == 0
                                ? null
                                : () => setDialogState(() {
                                      final moved = drafts.removeAt(index);
                                      drafts.insert(index - 1, moved);
                                    }),
                            onMoveDown: index == drafts.length - 1
                                ? null
                                : () => setDialogState(() {
                                      final moved = drafts.removeAt(index);
                                      drafts.insert(index + 1, moved);
                                    }),
                            onDelete: () =>
                                setDialogState(() => drafts.removeAt(index)),
                            onToggleObscure: () => setDialogState(
                              () => drafts[index].obscureKey = !drafts[index].obscureKey,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => setDialogState(
                    () => drafts.add(_ModelDraft.empty(nextDraftId++)),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加新模型'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '按列表顺序依次尝试，前一个失败自动换下一个。\n'
                  '支持任意 OpenAI 兼容接口；BaseUrl 只填到 /v1 会自动补 /chat/completions。\n'
                  'Key 仅保存在本机 SharedPreferences，不会上传到任何第三方。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final collected = drafts
                    .where((d) => !d.isBlank)
                    .map((d) => d.toModel())
                    .toList();
                await AppConfig.saveLlmModels(collected);
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;
    setState(() {});
    final models = AppConfig.getLlmModels();
    final usable = models.where((m) => m.isUsable).length;
    _toast(
      usable > 0
          ? '已保存 ${models.length} 个模型（可用 $usable 个）'
          : '已保存，但没有填写 API Key，AI 解题会失败',
    );
  }

  /// 单个模型配置卡片
  Widget _buildModelCard({
    required _ModelDraft draft,
    required int index,
    required VoidCallback onDelete,
    required VoidCallback onToggleObscure,
    VoidCallback? onMoveUp,
    VoidCallback? onMoveDown,
  }) {
    return Container(
      key: ValueKey<int>(draft.id),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.60),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '模型 ${index + 1}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withValues(alpha: 0.72),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '上移（优先级更高）',
                onPressed: onMoveUp,
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: '下移（优先级更低）',
                onPressed: onMoveDown,
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Color(0xFFD32F2F),
                ),
              ),
            ],
          ),
          _buildConfigField(
            label: '名称',
            initialValue: draft.name,
            hint: '例如 DeepSeek / Kimi / 豆包',
            onChanged: (value) => draft.name = value,
          ),
          _buildConfigField(
            label: 'BaseUrl',
            initialValue: draft.baseUrl,
            hint: AppConfig.defaultDeepseekBaseUrl,
            onChanged: (value) => draft.baseUrl = value,
          ),
          _buildConfigField(
            label: 'Model',
            initialValue: draft.model,
            hint: AppConfig.defaultDeepseekModel,
            onChanged: (value) => draft.model = value,
          ),
          _buildConfigField(
            label: 'API Key',
            initialValue: draft.apiKey,
            hint: 'sk-...',
            obscure: draft.obscureKey,
            onChanged: (value) => draft.apiKey = value,
            suffix: IconButton(
              tooltip: draft.obscureKey ? '显示' : '隐藏',
              onPressed: onToggleObscure,
              icon: Icon(
                draft.obscureKey ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 弹窗内的单个配置输入框
  Widget _buildConfigField({
    required String label,
    required String initialValue,
    required String hint,
    required ValueChanged<String> onChanged,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        initialValue: initialValue,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          hintStyle: TextStyle(
            fontSize: 11.5,
            color: Colors.black.withValues(alpha: 0.30),
          ),
          hintMaxLines: 1,
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    await CookieSyncHelper.instance.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(),
            _buildViewSwitcher(),
            const SizedBox(height: 6),
            Expanded(
              child: _view == DashboardView.byCourse ? _buildCourseView() : _buildTaskView(),
            ),
            _buildFooter(),
          ],
        ),
      ),
      // 保留：手动进入学习通任意页（调试 / 兜底入口）
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openManualEntry,
        label: const Text('手动进入作业页'),
        icon: const Icon(Icons.web),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Text(
                      '作业',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '$_summaryText · $_highRiskCount 项高风险',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.black.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (kDebugMode)
            IconButton(
              onPressed: _openDebugUrlDialog,
              tooltip: '打开测试页（debug）',
              iconSize: 22,
              icon: Icon(Icons.bug_report_outlined, color: Colors.black.withValues(alpha: 0.55)),
            ),
          IconButton(
            onPressed: _openManualEntry,
            tooltip: '进页面提取作业',
            iconSize: 23,
            icon: Icon(Icons.playlist_add, color: Colors.black.withValues(alpha: 0.65)),
          ),
          IconButton(
            onPressed: _showKeyDialog,
            tooltip: '设置',
            iconSize: 24,
            icon: Icon(Icons.settings, color: Colors.black.withValues(alpha: 0.65)),
          ),
        ],
      ),
    );
  }

  /// 顶部视图切换：按课程 / 按作业
  Widget _buildViewSwitcher() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 42,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            _buildSegment(DashboardView.byCourse, '按课程视图', Icons.school_outlined),
            _buildSegment(DashboardView.byTask, '按作业视图', Icons.list_alt_outlined),
          ],
        ),
      ),
    );
  }

  Widget _buildSegment(DashboardView view, String label, IconData icon) {
    final selected = _view == view;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_view == view) return;
          setState(() => _view = view);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.black.withValues(alpha: 0.8) : Colors.black.withValues(alpha: 0.45),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Colors.black.withValues(alpha: 0.85) : Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 视图 A：按课程 ----------------

  Widget _buildCourseView() {
    if (_courses.isEmpty) return _buildEmptyState();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 100),
      itemCount: _courses.length,
      itemBuilder: (context, index) => _buildCourseCard(_courses[index]),
    );
  }

  Widget _buildCourseCard(CourseGroup course) {
    final nearest = course.nearest;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _showCourseTasks(course),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Row(
                  children: <Widget>[
                    // 课程色块
                    Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: course.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.menu_book_outlined, size: 22, color: course.accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            course.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black.withValues(alpha: course.hasTasks ? 0.88 : 0.45),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            course.hasTasks
                                ? '${course.teacher} · ${course.taskCount} 份待办'
                                : '${course.teacher} · 暂无待办',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black.withValues(alpha: 0.45),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (nearest != null) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        _countdownLabel(nearest),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: _statusColor(nearest),
                        ),
                      ),
                    ],
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: Colors.black.withValues(alpha: course.hasTasks ? 0.30 : 0.12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 右上角红点（带数字）
          if (course.hasTasks)
            Positioned(
              right: 10,
              top: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                constraints: const BoxConstraints(minWidth: 20),
                decoration: BoxDecoration(
                  color: _urgentColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${course.taskCount}',
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 视图 B：按作业 ----------------

  Widget _buildTaskView() {
    final tasks = _sortedTasks;
    if (tasks.isEmpty) return _buildEmptyState();

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 100),
      itemCount: tasks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildTaskTile(tasks[index]),
    );
  }

  /// 任务卡片（主列表与底部弹窗共用）
  Widget _buildTaskTile(CourseTask task) {
    final barColor = _statusColor(task);
    final dimmed = task.isExpired;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _onTaskTap(task),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 左侧状态竖条
              Container(width: 4, color: barColor),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 高风险锁
                          if (task.highRisk) ...<Widget>[
                            Icon(Icons.lock_rounded, size: 15, color: _riskColor),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(
                              task.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                                color: dimmed
                                    ? Colors.black.withValues(alpha: 0.40)
                                    : Colors.black.withValues(alpha: 0.88),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildCountdownPill(task),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              task.courseName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black.withValues(alpha: 0.48),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildTypeTag(task.type),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCountdownPill(CourseTask task) {
    final color = _statusColor(task);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        _countdownLabel(task),
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// 类型标签：普通作业绿色【可辅助】，高风险琥珀【🔒 仅提醒】
  Widget _buildTypeTag(TaskType type) {
    final isSafe = !type.highRisk;
    final fg = isSafe ? _safeColor : _riskColor;
    final bg = isSafe ? _safeBg : _riskBg;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!isSafe) ...<Widget>[
            Icon(Icons.lock_rounded, size: 10, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            type.label,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: fg, height: 1.2),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.inbox_outlined,
              size: 54,
              color: Colors.black.withValues(alpha: 0.18),
            ),
            const SizedBox(height: 14),
            Text(
              '还没有作业数据',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点下方按钮进入学习通，手动点到「课程 → 作业」，\n'
              '再点右上角的提取按钮，作业就会出现在这里。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Colors.black.withValues(alpha: 0.38),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _openManualEntry,
              icon: const Icon(Icons.web, size: 18),
              label: const Text('去提取作业'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.82),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      // 右侧留 96 给右下角悬浮按钮，避免按钮被盖住
      padding: const EdgeInsets.fromLTRB(16, 0, 96, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _keyStatusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.black.withValues(alpha: 0.32)),
            ),
          ),
          TextButton(
            onPressed: _logout,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              '退出登录',
              style: TextStyle(fontSize: 12, color: Colors.black.withValues(alpha: 0.40)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置弹窗里的「可编辑草稿」，字段可变，避免用 TextEditingController。
class _ModelDraft {
  _ModelDraft({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  factory _ModelDraft.empty(int id) => _ModelDraft(
        id: id,
        name: '',
        baseUrl: '',
        model: '',
        apiKey: '',
      );

  factory _ModelDraft.fromModel(LlmModel model, int id) => _ModelDraft(
        id: id,
        name: model.name,
        baseUrl: model.baseUrl,
        model: model.model,
        apiKey: model.apiKey,
      );

  final int id;
  String name;
  String baseUrl;
  String model;
  String apiKey;
  bool obscureKey = true;

  bool get isBlank =>
      name.trim().isEmpty &&
      baseUrl.trim().isEmpty &&
      model.trim().isEmpty &&
      apiKey.trim().isEmpty;

  LlmModel toModel() => LlmModel(
        name: name,
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
      );
}
