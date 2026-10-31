import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/network/cookie_sync_helper.dart';
import '../../data/services/course_store.dart';
import '../../data/services/scanner_service.dart';
import '../../data/services/task_store.dart';
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
    this.status = '未知',
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

  /// 页面上的状态文案：未交 / 待交 / 已交 …
  final String status;

  bool get highRisk => type.highRisk;

  /// 是否仍是要做的待办（已交 / 待批阅的一律不算）
  bool get isPending => HomeworkItem.isPendingStatus(status);

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

/// 视图模式：按课程 / 按作业 / 课程入口（快捷跳转）
enum DashboardView { byCourse, byTask, byShortcut }

/// 排序方式
enum SortMode {
  deadline('截止时间（紧急优先）'),
  course('课程名称');

  const SortMode(this.label);

  final String label;
}

/// 紧急程度：决定卡片左侧色条与倒计时胶囊配色
enum _Urgency { urgent, soon, normal, expired }

// ============================================================
// 页面
// ============================================================

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, this.previewCourses, this.previewShortcuts});

  /// 仅测试使用：注入这批课程数据，跳过本地缓存读取。
  /// 生产环境恒为 null，数据来自用户手动提取后落盘的缓存。
  final List<CourseGroup>? previewCourses;

  /// 仅测试使用：注入课程快捷入口，跳过本地缓存读取。
  final List<CourseRef>? previewShortcuts;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // ---- 视觉常量 ----
  static const Color _urgentColor = Color(0xFFE53935);
  static const Color _safeColor = Color(0xFF2E7D32);
  static const Color _expiredColor = Color(0xFF9E9E9E);
  static const Color _soonColor = Color(0xFFEF6C00);
  static const Color _riskColor = Color(0xFFB26A00);
  static const Color _riskBg = Color(0xFFFFF4E0);
  static const Color _safeBg = Color(0xFFE8F5E9);
  static const Color _pageBg = Color(0xFFF6F7F9);

  DashboardView _view = DashboardView.byCourse;
  SortMode _sortMode = SortMode.deadline;

  /// 缓存里的原始数据（唯一数据源，_courses 由它派生）
  List<HomeworkItem> _items = <HomeworkItem>[];
  List<CourseGroup> _courses = <CourseGroup>[];

  /// 课程快捷入口（课程名 + 课程地址），主页第三视图渲染它
  List<CourseRef> _shortcuts = <CourseRef>[];

  /// 每秒刷新的“当前时间”，驱动倒计时重建
  DateTime _now = DateTime.now();
  Timer? _ticker;

  /// 首帧读缓存期间显示 loading，避免闪一下空态
  bool _loadingCache = true;

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

    // 1) 每秒刷新倒计时；没数据时不做无谓重建
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _courses.isEmpty) return;
      setState(() => _now = DateTime.now());
    });

    // 2) 恢复上次的视图选择
    TaskStore.loadView().then((value) {
      if (!mounted || value == null) return;
      final restored = DashboardView.values.firstWhere(
        (v) => v.name == value,
        orElse: () => DashboardView.byCourse,
      );
      if (restored != _view) setState(() => _view = restored);
    });

    // 3) 数据来源：调试注入 or 本地缓存（不做任何自动抓取）
    final injected = widget.previewCourses;
    if (injected != null) {
      _courses = injected;
      _loadingCache = false;
      _loadShortcuts();
      return;
    }
    _loadCached();
  }

  /// 课程快捷入口单独加载：它和作业数据在业务上互不影响
  Future<void> _loadShortcuts() async {
    final injected = widget.previewShortcuts;
    if (injected != null) {
      if (!mounted) return;
      setState(() => _shortcuts = injected);
      return;
    }

    final courses = await CourseStore.load();
    if (!mounted) return;
    setState(() => _shortcuts = courses);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 启动时从本地恢复上次提取的作业
  Future<void> _loadCached() async {
    final items = await TaskStore.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _courses = _groupByCourse(items);
      _now = DateTime.now();
      _loadingCache = false;
    });
    await _loadShortcuts();
  }

  // ---------------- 数据 ----------------

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
    // 在里面可能点了「保存全部课程」，回来刷新快捷入口
    await _loadShortcuts();
    _handleImported(imported);
  }

  /// 直接跳进某门课（快捷卡片）：地址里带着课程 id、cpi，
  /// 若这门课之前进过作业列表，还会带上 enc，能一步到位。
  Future<void> _openCourseEntry(CourseRef course) async {
    final imported = await Navigator.of(context).push<List<HomeworkItem>>(
      MaterialPageRoute<List<HomeworkItem>>(
        builder: (_) => WorkWebViewPage(
          workTitle: course.courseName,
          workUrl: course.entryUrl,
        ),
      ),
    );
    await _loadShortcuts();
    _handleImported(imported);
  }

  /// 打开课程列表页，让用户点右上角「保存全部课程」批量建快捷入口
  Future<void> _openCourseImport() async {
    await Navigator.of(context).push<List<HomeworkItem>>(
      MaterialPageRoute<List<HomeworkItem>>(
        builder: (_) => const WorkWebViewPage(
          workTitle: '课程列表（点右上角保存全部）',
          workUrl: 'https://mooc1.chaoxing.com/visit/interaction',
        ),
      ),
    );
    await _loadShortcuts();
    if (!mounted) return;
    if (_shortcuts.isNotEmpty) {
      setState(() => _view = DashboardView.byShortcut);
      TaskStore.saveView(DashboardView.byShortcut.name);
    }
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
  /// HomeworkItem → CourseTask
  CourseTask _toTask(HomeworkItem item) => CourseTask(
        title: item.title,
        courseName: item.courseName,
        type: _inferType(item),
        deadline: item.deadline ?? DateTime.now().add(const Duration(days: 30)),
        url: item.url,
        deadlineUnknown: item.deadline == null,
        identity: item.identity,
        status: item.status,
      );

  /// 按课程分组（保持首次出现顺序）
  List<CourseGroup> _groupByCourse(List<HomeworkItem> items) {
    final grouped = <String, List<HomeworkItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.courseName, () => <HomeworkItem>[]).add(item);
    }

    var index = 0;
    final courses = <CourseGroup>[];
    grouped.forEach((name, groupItems) {
      final tasks = groupItems.map(_toTask).toList()
        ..sort((a, b) => a.deadline.compareTo(b.deadline));
      courses.add(
        CourseGroup(
          name: name,
          teacher: '共 ${tasks.length} 份任务',
          tasks: tasks,
          accent: _coursePalette[index % _coursePalette.length],
        ),
      );
      index++;
    });
    return courses;
  }

  /// 作业视图：按当前排序方式排列
  List<CourseTask> get _sortedTasks {
    final all = _courses.expand((c) => c.tasks).toList();
    all.sort((a, b) {
      if (_sortMode == SortMode.course) {
        final byCourse = a.courseName.compareTo(b.courseName);
        if (byCourse != 0) return byCourse;
      }
      return a.deadline.compareTo(b.deadline);
    });
    return all;
  }

  /// 课程视图：按当前排序方式排列
  List<CourseGroup> get _sortedCourses {
    final list = List<CourseGroup>.of(_courses);
    if (_sortMode == SortMode.course) {
      list.sort((a, b) => a.name.compareTo(b.name));
      return list;
    }
    list.sort((a, b) {
      final da = a.nearest?.deadline;
      final db = b.nearest?.deadline;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });
    return list;
  }

  /// 待办数量：**只按状态数**——网页上显示几条「未交/待交」，这里就是几条。
  ///
  /// 不再排除已过期的：过期的作业在网页上仍然是「未交」，两边数量要能对上；
  /// 过期与否只影响颜色和倒计时，不影响「它还没交」这个事实。
  int get _pendingCount =>
      _courses.expand((c) => c.tasks).where((t) => t.isPending).length;

  /// 紧急数量：同样只数未交的（已交的再急也不用做了）
  int get _urgentCount => _courses
      .expand((c) => c.tasks)
      .where((t) => t.isPending && _urgency(t, _now) == _Urgency.urgent)
      .length;

  int get _highRiskCount => _courses
      .expand((c) => c.tasks)
      .where((t) => t.isPending && t.highRisk)
      .length;

  String get _keyStatusText {
    final models = AppConfig.getLlmModels();
    if (models.isEmpty) return '模型：未配置（点右上角设置添加）';
    final usable = models.where((m) => m.hasKey).length;
    final names = models.map((m) => m.label).join(' / ');
    return '模型 $usable/${models.length}：$names';
  }

  // ---------------- 状态颜色 / 文案 ----------------

  /// 紧急程度（以当前时间计算，随 ticker 每秒变化）
  _Urgency _urgency(CourseTask task, DateTime now) {
    if (task.deadlineUnknown) return _Urgency.normal;
    final diff = task.deadline.difference(now);
    if (diff.isNegative) return _Urgency.expired;
    if (diff.inHours < 24) return _Urgency.urgent;
    if (diff.inHours < 72) return _Urgency.soon;
    return _Urgency.normal;
  }

  Color _urgencyColor(CourseTask task, DateTime now) {
    switch (_urgency(task, now)) {
      case _Urgency.expired:
        return _expiredColor;
      case _Urgency.urgent:
        return _urgentColor;
      case _Urgency.soon:
        return _soonColor;
      case _Urgency.normal:
        return _safeColor;
    }
  }

  /// ⏳ 剩 2天14小时 / 🔥 剩 3小时12分 / 已过期
  String _countdownText(CourseTask task, DateTime now) {
    if (task.deadlineUnknown) return '待定';
    final diff = task.deadline.difference(now);
    if (diff.isNegative) return '已过期';

    if (diff.inHours < 24) {
      final hours = diff.inHours;
      final minutes = diff.inMinutes % 60;
      return hours > 0 ? '🔥 剩 $hours小时$minutes分' : '🔥 剩 $minutes 分';
    }
    final days = diff.inDays;
    final hours = diff.inHours % 24;
    return '⏳ 剩 $days天$hours小时';
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

  /// 接收 WorkWebViewPage 回传的作业并写入看板。
  ///
  /// **覆盖式更新**（不再是取并集）：本次提取涉及到的课程，旧数据整批丢弃，
  /// 只用网页最新结果替换；其他课程原样保留。规则细节见
  /// [TaskStore.mergeExtraction]（纯函数，有单测）。
  Future<void> _handleImported(List<HomeworkItem>? items) async {
    if (items == null || items.isEmpty) return;

    final merged = TaskStore.mergeExtraction(_items, items);
    if (merged.added == 0) {
      // 全是被过滤掉的脏数据：不覆盖、不清空，保持原样
      if (!mounted) return;
      _toast('本页没有「未交」的作业，本地缓存未改动');
      return;
    }

    if (!mounted) return;
    setState(() {
      _items = merged.items;
      _courses = _groupByCourse(merged.items);
      _now = DateTime.now();
    });

    await TaskStore.save(merged.items);
    if (!mounted) return;

    final parts = <String>['已更新 ${merged.added} 条未交作业'];
    if (merged.replaced > 0) parts.add('覆盖旧数据 ${merged.replaced} 条');
    if (merged.dropped > 0) parts.add('过滤 ${merged.dropped} 条');
    _toast(parts.join(' · '));
  }

  /// 清空本地缓存（二次确认，避免误触）
  Future<void> _confirmClear() async {
    if (_courses.isEmpty) {
      _toast('当前没有可清空的数据');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空本地数据'),
        content: const Text('将删除本地缓存的全部作业记录（不影响学习通上的实际作业）。'),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await TaskStore.clear();
    if (!mounted) return;
    setState(() {
      _items = <HomeworkItem>[];
      _courses = <CourseGroup>[];
    });
    _toast('本地数据已清空');
  }

  void _changeView(DashboardView view) {
    if (view == _view) return;
    setState(() => _view = view);
    TaskStore.saveView(view.name);
  }

  void _changeSort(SortMode mode) {
    if (mode == _sortMode) return;
    setState(() => _sortMode = mode);
  }

  /// 高风险任务：只允许系统外部浏览器，绝不进内置 WebView  /// 高风险任务：只允许系统外部浏览器，绝不进内置 WebView
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
                  itemBuilder: (_, index) => _buildTaskTile(sorted[index], DateTime.now()),
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
            hint: '粘贴服务商控制台里的 API Key',
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

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    if (_loadingCache) {
      return const Scaffold(
        backgroundColor: _pageBg,
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }

    final now = _now;

    return Scaffold(
      backgroundColor: _pageBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildGradientHeader(),
            _buildToolbar(),
            Expanded(
              // 双视图切换动画：淡入 + 轻微上滑
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final offset = Tween<Offset>(
                    begin: const Offset(0, 0.03),
                    end: Offset.zero,
                  ).animate(animation);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: offset, child: child),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<DashboardView>(_view),
                  child: switch (_view) {
                    DashboardView.byCourse => _buildCourseView(now),
                    DashboardView.byTask => _buildTaskView(now),
                    DashboardView.byShortcut => _buildShortcutView(),
                  },
                ),
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
      // 悬浮按钮随视图切换：课程入口页给「导入课程」，其余给「读取作业」
      floatingActionButton: _view == DashboardView.byShortcut
          ? FloatingActionButton.extended(
              onPressed: _openCourseImport,
              label: const Text('导入课程'),
              icon: const Icon(Icons.menu_book_outlined),
            )
          : FloatingActionButton.extended(
              onPressed: _openManualEntry,
              label: const Text('读取作业'),
              icon: const Icon(Icons.download_rounded),
            ),
    );
  }

  /// 顶部渐变统计面板
  Widget _buildGradientHeader() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.fromLTRB(18, 8, 6, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3D5AFE), Color(0xFF7C4DFF)],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF3D5AFE).withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '作业看板',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Colors.white,
                  ),
                ),
              ),
              PopupMenuButton<SortMode>(
                tooltip: '排序方式',
                initialValue: _sortMode,
                onSelected: _changeSort,
                icon: const Icon(Icons.swap_vert_rounded, color: Colors.white, size: 22),
                itemBuilder: (context) => SortMode.values
                    .map(
                      (mode) => PopupMenuItem<SortMode>(
                        value: mode,
                        child: Row(
                          children: <Widget>[
                            Icon(
                              mode == _sortMode ? Icons.check_circle : Icons.circle_outlined,
                              size: 16,
                              color: mode == _sortMode
                                  ? const Color(0xFF3D5AFE)
                                  : Colors.black26,
                            ),
                            const SizedBox(width: 8),
                            Text(mode.label),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
              IconButton(
                tooltip: '模型设置',
                onPressed: _showKeyDialog,
                icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '总待办：$_pendingCount 项 · 紧急：$_urgentCount 项',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${_courses.length} 门课程 · $_highRiskCount 项高风险 · ${_sortMode.label}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white.withValues(alpha: 0.80),
            ),
          ),
        ],
      ),
    );
  }

  /// 视图切换 + 操作入口
  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SegmentedButton<DashboardView>(
              segments: const <ButtonSegment<DashboardView>>[
                ButtonSegment<DashboardView>(
                  value: DashboardView.byCourse,
                  label: Text('课程'),
                ),
                ButtonSegment<DashboardView>(
                  value: DashboardView.byTask,
                  label: Text('作业'),
                ),
                ButtonSegment<DashboardView>(
                  value: DashboardView.byShortcut,
                  label: Text('入口'),
                ),
              ],
              selected: <DashboardView>{_view},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => _changeView(selection.first),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          IconButton(
            tooltip: '重新提取（覆盖旧数据）',
            onPressed: _openManualEntry,
            icon: const Icon(Icons.refresh_rounded, size: 22),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) {
              if (value == 'clear') _confirmClear();
              if (value == 'import') _openCourseImport();
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'import',
                child: Row(
                  children: <Widget>[
                    Icon(Icons.menu_book_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('导入课程入口'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'clear',
                child: Row(
                  children: <Widget>[
                    Icon(Icons.delete_sweep_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('清空本地数据'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 视图 A：按课程 ----------------

  Widget _buildCourseView(DateTime now) {
    final courses = _sortedCourses;
    if (courses.isEmpty) return _buildEmptyState();

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 96),
      itemCount: courses.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildCourseCard(courses[index], now),
    );
  }

  Widget _buildCourseCard(CourseGroup course, DateTime now) {
    final nearest = course.nearest;
    final accent = course.accent;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showCourseTasks(course),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.menu_book_outlined, size: 22, color: accent),
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
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      nearest == null ? '暂无待办' : '最近：${_countdownText(nearest, now)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
              if (course.taskCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE53935),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${course.taskCount}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 20, color: Colors.black.withValues(alpha: 0.22)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 视图 B：按作业 ----------------

  Widget _buildTaskView(DateTime now) {
    final tasks = _sortedTasks;
    if (tasks.isEmpty) return _buildEmptyState();

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 96),
      itemCount: tasks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildTaskTile(tasks[index], now),
    );
  }

  // ---------------- 视图 C：课程快捷入口 ----------------

  /// 课程名 → 该课程待办数量（用于卡片右上角红点）
  Map<String, int> get _taskCountByCourse {
    final map = <String, int>{};
    for (final course in _courses) {
      map[course.name] = course.taskCount;
    }
    return map;
  }

  Widget _buildShortcutView() {
    if (_shortcuts.isEmpty) return _buildShortcutEmptyState();

    final counts = _taskCountByCourse;
    final sorted = List<CourseRef>.of(_shortcuts)
      ..sort((a, b) {
        // 有待办的排前面，其次按课程名
        final pa = counts[a.courseName] ?? 0;
        final pb = counts[b.courseName] ?? 0;
        if (pa != pb) return pb.compareTo(pa);
        return a.courseName.compareTo(b.courseName);
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 96),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '共 ${_shortcuts.length} 门课程 · 点卡片直接进课程页面',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.black.withValues(alpha: 0.40),
            ),
          ),
        ),
        for (var i = 0; i < sorted.length; i += 2) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _buildShortcutCard(sorted[i], i, counts),
              ),
              const SizedBox(width: 10),
              if (i + 1 < sorted.length)
                Expanded(child: _buildShortcutCard(sorted[i + 1], i + 1, counts))
              else
                const Expanded(child: SizedBox()),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildShortcutCard(
    CourseRef course,
    int index,
    Map<String, int> counts,
  ) {
    final accent = _coursePalette[index % _coursePalette.length];
    final pending = counts[course.courseName] ?? 0;
    final hasEnc = course.enc.isNotEmpty;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openCourseEntry(course),
        onLongPress: () => _confirmRemoveShortcut(course),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(Icons.menu_book_outlined, size: 18, color: accent),
                  ),
                  const Spacer(),
                  if (pending > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '$pending',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                course.courseName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                hasEnc ? '直达作业列表' : '打开课程主页',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: hasEnc
                      ? const Color(0xFF2E7D32)
                      : Colors.black.withValues(alpha: 0.40),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 长按卡片 → 删除这门课的快捷入口
  Future<void> _confirmRemoveShortcut(CourseRef course) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除课程入口'),
        content: Text('将移除「${course.courseName}」的快捷入口，不影响学习通上的课程本身。'),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(false);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('移除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await CourseStore.remove(course.key);
    await _loadShortcuts();
    if (!mounted) return;
    _toast('已移除「${course.courseName}」');
  }

  Widget _buildShortcutEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.dashboard_customize_outlined,
              size: 56,
              color: Colors.black.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 14),
            Text(
              '还没有课程入口',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点下面的按钮打开学习通课程列表，\n'
              '等课程卡片显示出来后，点右上角「保存全部课程」，\n'
              '就能一次性把整页课程存成快捷卡片。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Colors.black.withValues(alpha: 0.38),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _openCourseImport,
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: const Text('导入课程'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 任务卡片（主列表与课程弹窗共用）
  Widget _buildTaskTile(CourseTask task, DateTime now) {
    final barColor = _urgencyColor(task, now);
    final dimmed = _urgency(task, now) == _Urgency.expired;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _onTaskTap(task),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 左侧紧急程度色条
              Container(width: 5, color: barColor),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (task.highRisk) ...<Widget>[
                            const Icon(Icons.lock_rounded, size: 15, color: _riskColor),
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
                                    ? Colors.black.withValues(alpha: 0.38)
                                    : Colors.black.withValues(alpha: 0.88),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildCountdownChip(task, now),
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
                          if (_hasStatusText(task)) ...<Widget>[
                            const SizedBox(width: 6),
                            _buildStatusTag(task.status),
                          ],
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

  /// 页面给出了明确状态（未交/待交…）才显示，避免「未知」也占一个标签
  bool _hasStatusText(CourseTask task) {
    final value = task.status.trim();
    return value.isNotEmpty && value != '未知';
  }

  /// 状态小标签：未交红字，其他中性灰
  Widget _buildStatusTag(String raw) {
    final value = raw.trim();
    final pending = HomeworkItem.isPendingStatus(value);
    final color = pending ? _urgentColor : _expiredColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// 倒计时胶囊：<24h 红底白字，<72h 橙色，其余绿色，过期灰色
  Widget _buildCountdownChip(CourseTask task, DateTime now) {
    final urgency = _urgency(task, now);
    final Color bg;
    final Color fg;

    switch (urgency) {
      case _Urgency.urgent:
        bg = _urgentColor;
        fg = Colors.white;
      case _Urgency.soon:
        bg = _soonColor.withValues(alpha: 0.12);
        fg = _soonColor;
      case _Urgency.expired:
        bg = const Color(0xFFF0F1F3);
        fg = _expiredColor;
      case _Urgency.normal:
        bg = _safeColor.withValues(alpha: 0.12);
        fg = _safeColor;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _countdownText(task, now),
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }

  /// 类型标签：普通作业绿色，高风险琥珀色带锁
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
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: fg,
              height: 1.2,
            ),
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
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.inbox_outlined,
              size: 56,
              color: Colors.black.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 14),
            Text(
              '暂无待办数据',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点「读取作业」进入学习通，手动点到「课程 → 作业」页面，\n'
              '再点右上角的提取按钮；提取结果会自动保存在本地。\n'
              '想少找几次课？先到「入口」页把课程存成快捷卡片。',
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
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('读取作业'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      // 右侧留 140 给「读取作业」悬浮按钮，避免按钮被盖住
      padding: const EdgeInsets.fromLTRB(16, 0, 140, 8),
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
