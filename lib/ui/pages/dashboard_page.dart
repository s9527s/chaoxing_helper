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
import '../theme/app_theme.dart';

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
    this.stableKey,
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

  /// 与本地缓存里 [HomeworkItem.stableKey] 对齐的键（侧滑删除按它对号入座）
  final String? stableKey;

  /// 侧滑删除 / 列表 key 用的唯一行标识
  String get rowKey {
    final stable = stableKey;
    if (stable != null && stable.isNotEmpty) return stable;
    final id = identity;
    if (id != null && id.isNotEmpty) return id;
    return 'sig:$courseName|$title|${deadline.toIso8601String()}';
  }

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
  // ---- 视觉常量（全部取自全局设计 token） ----
  static const Color _riskColor = Color(0xFFB45309);
  static const Color _riskBg = Color(0xFFFEF3C7);
  static const Color _safeBg = AppColors.primaryContainer;
  static const Color _pageBg = AppColors.bg;

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

  /// 数据版本号：导入/删除后 +1，用来给列表做平滑过渡动画
  int _dataVersion = 0;

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
      // 注入模式下也补一份 _items：侧滑删除要按稳定键从原始列表里摘掉这条
      _items = <HomeworkItem>[
        for (final course in injected)
          for (final task in course.tasks)
            HomeworkItem(
              courseName: task.courseName,
              title: task.title,
              kind: task.type == TaskType.homework
                  ? HomeworkKind.homework
                  : HomeworkKind.exam,
              url: task.url,
              status: task.status,
              deadline: task.deadlineUnknown ? null : task.deadline,
            ),
      ];
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

    if (title.contains('实验') && title.contains('论文')) {
      return TaskType.experiment;
    }
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
    stableKey: item.stableKey,
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
        builder: (_) =>
            WorkWebViewPage(workTitle: task.title, workUrl: task.url),
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
      _dataVersion++;
    });

    await TaskStore.save(merged.items);
    if (!mounted) return;

    final parts = <String>['已更新 ${merged.added} 条未交作业'];
    if (merged.replaced > 0) parts.add('覆盖旧数据 ${merged.replaced} 条');
    if (merged.dropped > 0) parts.add('过滤 ${merged.dropped} 条');
    _toast(parts.join(' · '));
  }

  // ---------------- 侧滑删除（交了作业就让它消失） ----------------

  /// 从看板与本地缓存里彻底移除一条作业。
  ///
  /// 用户在图上的操作：在网页上把作业交了 → 回看板往左滑这条卡片 → 它立刻消失，
  /// 缓存同时被覆盖写，杀掉进程重进也不会再出现。
  void _removeTask(CourseTask task) {
    final snapshot = List<HomeworkItem>.of(_items);
    final key = task.rowKey;

    var next = _items.where((e) => e.stableKey != key).toList();
    if (next.length == _items.length) {
      // 缓存里没有完全一致的稳定键（老数据/兜底签名）→ 退化成「课程 + 标题」
      next = _items
          .where(
            (e) => !(e.courseName == task.courseName && e.title == task.title),
          )
          .toList();
    }
    if (next.length == _items.length) return;

    setState(() {
      _items = next;
      _courses = _groupByCourse(next);
      _dataVersion++;
    });
    unawaited(_persist(next));
    _toastUndo(task, snapshot);
  }

  /// 落盘（覆盖写）。写失败只打日志：界面上这条记录已经删掉了，不能因此崩掉。
  Future<void> _persist(List<HomeworkItem> items) async {
    try {
      await TaskStore.save(items);
    } catch (e) {
      debugPrint('[Dashboard] 缓存写入失败: $e');
    }
  }

  /// 删除后的提示条：带「撤销」，误滑了可以立刻找回
  void _toastUndo(CourseTask task, List<HomeworkItem> snapshot) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已移除「${task.title}」'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              if (!mounted) return;
              setState(() {
                _items = snapshot;
                _courses = _groupByCourse(snapshot);
                _dataVersion++;
              });
              unawaited(_persist(snapshot));
            },
          ),
        ),
      );
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
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
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
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
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
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.panel),
        ),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
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
                      color: const Color(0xFFCBD5E1),
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
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    Text(
                      '${sorted.length} 份待办',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.secondary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: () {
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                      },
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: AppColors.secondary,
                      ),
                      tooltip: '关闭',
                    ),
                  ],
                ),
                const Text(
                  '按截止时间倒序排列',
                  style: TextStyle(fontSize: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 4),
                    itemCount: sorted.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (_, index) {
                      final task = sorted[index];
                      return Dismissible(
                        key: ValueKey<String>('sheet-dismiss-${task.rowKey}'),
                        direction: DismissDirection.endToStart,
                        background: _buildDismissBackground(),
                        onDismissed: (_) {
                          setSheetState(() => sorted.removeAt(index));
                          _removeTask(task);
                        },
                        child: _buildTaskTile(task, DateTime.now()),
                      );
                    },
                  ),
                ),
              ],
            ),
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

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x660F172A),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
          return Container(
            constraints: BoxConstraints(maxHeight: maxHeight),
            decoration: const BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppRadius.panel),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 10),
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 2),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.tune_rounded,
                          size: 18,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '模型设置',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () =>
                              Navigator.of(sheetContext).pop(false),
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: AppColors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
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
                                () => drafts[index].obscureKey =
                                    !drafts[index].obscureKey,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton.icon(
                      onPressed: () => setDialogState(
                        () => drafts.add(_ModelDraft.empty(nextDraftId++)),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('添加新模型'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white,
                        side: const BorderSide(color: AppColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                      '按列表顺序依次尝试，前一个失败自动换下一个。\n'
                      '支持任意 OpenAI 兼容接口；BaseUrl 只填到 /v1 会自动补 /chat/completions。\n'
                      'Key 仅保存在本机 SharedPreferences，不会上传到任何第三方。',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.6,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(false),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                            ),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              final collected = drafts
                                  .where((d) => !d.isBlank)
                                  .map((d) => d.toModel())
                                  .toList();
                              // Key 写加密存储失败时不能关弹窗：
                              // 否则用户以为存上了，实际下次启动 Key 就没了
                              final saved = await AppConfig.saveLlmModels(collected);
                              if (!saved) {
                                if (!sheetContext.mounted) return;
                                ScaffoldMessenger.of(sheetContext)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    const SnackBar(
                                      content: Text('API Key 写入系统加密存储失败，请重试'),
                                    ),
                                  );
                                return;
                              }
                              if (!sheetContext.mounted) return;
                              Navigator.of(sheetContext).pop(true);
                            },
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                            ),
                            child: const Text('保存'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '模型 ${index + 1}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '上移（优先级更高）',
                onPressed: onMoveUp,
                visualDensity: VisualDensity.compact,
                iconSize: 19,
                color: AppColors.secondary,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
              IconButton(
                tooltip: '下移（优先级更低）',
                onPressed: onMoveDown,
                visualDensity: VisualDensity.compact,
                iconSize: 19,
                color: AppColors.secondary,
                icon: const Icon(Icons.arrow_downward_rounded),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 19,
                  color: AppColors.danger,
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

  /// 弹窗内的单个配置输入框（填充式：浅灰底、10 圆角、无边框）
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
        style: const TextStyle(fontSize: 13.5, color: AppColors.ink),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintMaxLines: 1,
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
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
        body: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }

    final now = _now;

    return Scaffold(
      backgroundColor: _pageBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildStatCard(),
            _buildModelChip(),
            _buildSegmentTabs(),
            Expanded(
              // 视图切换动画：淡入 + 轻微上滑
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
          ],
        ),
      ),
      // 悬浮按钮随视图切换：课程入口页给「导入课程」，其余给「读取作业」
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _view == DashboardView.byShortcut
            ? _openCourseImport
            : _openManualEntry,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        highlightElevation: 0,
        extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        label: Text(_view == DashboardView.byShortcut ? '导入课程' : '读取作业'),
        icon: Icon(
          _view == DashboardView.byShortcut
              ? Icons.menu_book_outlined
              : Icons.download_rounded,
          size: 20,
        ),
      ),
    );
  }

  /// 顶部统计大卡片：主色渐变 + 流光 + 三块等宽毛玻璃小卡
  Widget _buildStatCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[AppColors.primary, AppColors.violet],
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x204F46E5),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      // 裁切只作用于内容：渐变底与外侧阴影留在外层 Container
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: <Widget>[
            const Positioned.fill(child: _CardShimmer()),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          '作业看板',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      PopupMenuButton<SortMode>(
                        tooltip: '排序方式',
                        initialValue: _sortMode,
                        onSelected: _changeSort,
                        position: PopupMenuPosition.under,
                        itemBuilder: (context) => SortMode.values
                            .map(
                              (mode) => PopupMenuItem<SortMode>(
                                value: mode,
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      mode == _sortMode
                                          ? Icons.check_circle_rounded
                                          : Icons.circle_outlined,
                                      size: 16,
                                      color: mode == _sortMode
                                          ? AppColors.primary
                                          : AppColors.muted,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(mode.label),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        child: _buildHeaderIcon(Icons.swap_vert_rounded),
                      ),
                      _buildHeaderIcon(
                        Icons.settings_outlined,
                        tooltip: '模型设置',
                        onTap: _showKeyDialog,
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        position: PopupMenuPosition.under,
                        onSelected: (value) {
                          if (value == 'clear') _confirmClear();
                          if (value == 'import') _openCourseImport();
                          if (value == 'logout') _logout();
                        },
                        itemBuilder: (context) =>
                            const <PopupMenuEntry<String>>[
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
                              PopupMenuDivider(height: 8),
                              PopupMenuItem<String>(
                                value: 'logout',
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.logout_rounded,
                                      size: 18,
                                      color: AppColors.danger,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      '退出登录',
                                      style: TextStyle(color: AppColors.danger),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                        child: _buildHeaderIcon(Icons.more_horiz_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _buildStatTile(
                          '总待办',
                          _pendingCount,
                          const ValueKey<String>('stat-pending'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatTile(
                          '紧急',
                          _urgentCount,
                          const ValueKey<String>('stat-urgent'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatTile(
                          '高风险',
                          _highRiskCount,
                          const ValueKey<String>('stat-risk'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 看板右上角的圆形图标按钮（半透明白底）
  Widget _buildHeaderIcon(
    IconData icon, {
    String? tooltip,
    VoidCallback? onTap,
  }) {
    final child = Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 19, color: Colors.white),
      ),
    );
    if (onTap == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: tooltip == null ? child : Tooltip(message: tooltip, child: child),
    );
  }

  /// 毛玻璃质感的小统计卡（数字 32sp，等宽，变化时平滑滚动）
  Widget _buildStatTile(String label, int count, Key valueKey) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _AnimatedCount(
            value: count,
            valueKey: valueKey,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              height: 1.05,
              letterSpacing: -0.5,
              color: Colors.white,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              letterSpacing: 0.2,
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ],
      ),
    );
  }

  /// 看板下方的模型胶囊：点一下打开模型设置
  Widget _buildModelChip() {
    final models = AppConfig.getLlmModels();
    final usable = models.where((m) => m.hasKey).length;
    final label = models.isEmpty ? '模型 未配置' : '模型 $usable/${models.length}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          key: const ValueKey<String>('model-chip'),
          behavior: HitTestBehavior.opaque,
          onTap: _showKeyDialog,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.memory_rounded,
                  size: 14,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _viewLabel(DashboardView view) {
    switch (view) {
      case DashboardView.byCourse:
        return '课程';
      case DashboardView.byTask:
        return '作业';
      case DashboardView.byShortcut:
        return '入口';
    }
  }

  /// 自定义滑动胶囊选项卡（替代 SegmentedButton）
  Widget _buildSegmentTabs() {
    const views = DashboardView.values;
    final index = views.indexOf(_view);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Container(
        height: 42,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.fill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / views.length;
            return Stack(
              children: <Widget>[
                AnimatedAlign(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment(-1 + 2 * index / (views.length - 1), 0),
                  child: Container(
                    width: tabWidth,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x140F172A),
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: <Widget>[
                    for (final view in views)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _changeView(view),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: view == _view
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                color: view == _view
                                    ? AppColors.primary
                                    : AppColors.secondary,
                              ),
                              child: Text(_viewLabel(view)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------------- 视图 A：按课程 ----------------

  Widget _buildCourseView(DateTime now) {
    final courses = _sortedCourses;
    if (courses.isEmpty) return _buildEmptyState();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      child: GridView.builder(
        // 导入 / 删除后整表换一批，用淡入过渡而不是硬闪
        key: ValueKey<String>('course-grid-$_dataVersion'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          mainAxisExtent: 152,
        ),
        itemCount: courses.length,
        itemBuilder: (context, index) => _Entrance(
          index: index,
          child: _buildCourseCard(courses[index], now),
        ),
      ),
    );
  }

  /// 课程网格卡片：44 图标 + 右上角待办徽章 + 课程名 + 最近截止
  Widget _buildCourseCard(CourseGroup course, DateTime now) {
    final nearest = course.nearest;
    final pending = course.tasks.where((t) => t.isPending).length;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showCourseTasks(course),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.menu_book_rounded,
                      size: 22,
                      color: AppColors.primary,
                    ),
                  ),
                  const Spacer(),
                  _buildCountBadge(
                    pending,
                    key: ValueKey<String>('course-badge-${course.name}'),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                course.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                nearest == null ? '暂无待办' : '最近：${_countdownText(nearest, now)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右上角待办数字徽章（柔和红色胶囊，严格右对齐）
  Widget _buildCountBadge(int count, {Key? key}) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      constraints: const BoxConstraints(minHeight: 20, minWidth: 22),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1.3,
        ),
      ),
    );
  }

  // ---------------- 视图 B：按作业 ----------------

  Widget _buildTaskView(DateTime now) {
    final tasks = _sortedTasks;
    if (tasks.isEmpty) return _buildEmptyState();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      // 导入 / 删除后整表换一批数据，用淡入过渡而不是硬闪
      child: ListView.separated(
        key: ValueKey<String>('task-list-$_dataVersion'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        itemCount: tasks.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final task = tasks[index];
          return _Entrance(
            index: index,
            child: Dismissible(
              key: ValueKey<String>('task-dismiss-${task.rowKey}'),
              direction: DismissDirection.endToStart,
              dismissThresholds: const <DismissDirection, double>{
                DismissDirection.endToStart: 0.32,
              },
              background: _buildDismissBackground(),
              onDismissed: (_) => _removeTask(task),
              child: _buildTaskTile(task, now),
            ),
          );
        },
      ),
    );
  }

  /// 左滑时露出的底色：红底 + 「交了，移除」
  Widget _buildDismissBackground() {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[Color(0xFFFEE2E2), AppColors.danger],
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
          SizedBox(width: 6),
          Text(
            '交了，移除',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 2),
          child: Text(
            '共 ${_shortcuts.length} 门课程 · 点卡片直接进课程页面',
            style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              mainAxisExtent: 152,
            ),
            itemCount: sorted.length,
            itemBuilder: (context, index) => _Entrance(
              index: index,
              child: _buildShortcutCard(sorted[index], index, counts),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShortcutCard(
    CourseRef course,
    int index,
    Map<String, int> counts,
  ) {
    final pending = counts[course.courseName] ?? 0;
    final hasEnc = course.enc.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openCourseEntry(course),
        onLongPress: () => _confirmRemoveShortcut(course),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.folder_open_rounded,
                      size: 22,
                      color: AppColors.primary,
                    ),
                  ),
                  const Spacer(),
                  _buildCountBadge(pending),
                ],
              ),
              const Spacer(),
              Text(
                course.courseName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  if (hasEnc) ...<Widget>[
                    const Icon(
                      Icons.bolt_rounded,
                      size: 12,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 2),
                  ],
                  Flexible(
                    child: Text(
                      hasEnc ? '直达作业列表' : '打开课程主页',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hasEnc ? AppColors.primary : AppColors.muted,
                      ),
                    ),
                  ),
                ],
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
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
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
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.dashboard_customize_rounded,
                size: 32,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '还没有课程入口',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '点下面的按钮打开学习通课程列表，\n'
              '等课程卡片显示出来后，点右上角「保存全部课程」，\n'
              '就能一次性把整页课程存成快捷卡片。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: AppColors.secondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openCourseImport,
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: const Text('导入课程'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
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
    final urgency = _urgency(task, now);
    final dimmed = urgency == _Urgency.expired;
    final barColor = switch (urgency) {
      _Urgency.urgent => AppColors.danger,
      _Urgency.soon => AppColors.warning,
      _Urgency.expired => const Color(0xFFCBD5E1),
      _Urgency.normal => AppColors.primary,
    };

    return Padding(
      // 卡片间距统一由列表的 separator（12dp）负责，这里不再额外留白
      padding: EdgeInsets.zero,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: () => _onTaskTap(task),
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.border),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 左侧 4dp 全圆角状态彩条
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 0, 16),
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (task.highRisk) ...<Widget>[
                                const Icon(
                                  Icons.lock_rounded,
                                  size: 14,
                                  color: AppColors.warning,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  task.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                    color: dimmed
                                        ? AppColors.muted
                                        : AppColors.ink,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _buildCountdownChip(task, now),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  task.courseName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.secondary,
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
        ),
      ),
    );
  }

  /// 页面给出了明确状态（未交/待交…）才显示，避免「未知」也占一个标签
  bool _hasStatusText(CourseTask task) {
    final value = task.status.trim();
    return value.isNotEmpty && value != '未知';
  }

  /// 状态胶囊：高 22、圆角 6、浅底色
  Widget _buildStatusTag(String raw) {
    final value = raw.trim();
    final pending = HomeworkItem.isPendingStatus(value);
    final fg = pending ? AppColors.danger : AppColors.secondary;
    final bg = pending ? const Color(0xFFFEE2E2) : AppColors.fill;

    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
          color: fg,
        ),
      ),
    );
  }

  /// 倒计时胶囊：紧急红、临期琥珀、常规主色、过期灰
  Widget _buildCountdownChip(CourseTask task, DateTime now) {
    final urgency = _urgency(task, now);
    final Color bg;
    final Color fg;

    switch (urgency) {
      case _Urgency.urgent:
        bg = const Color(0xFFFEE2E2);
        fg = AppColors.danger;
      case _Urgency.soon:
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFFB45309);
      case _Urgency.expired:
        bg = AppColors.fill;
        fg = AppColors.muted;
      case _Urgency.normal:
        bg = AppColors.primaryContainer;
        fg = AppColors.primary;
    }

    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _countdownText(task, now),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.2,
          color: fg,
          // 等宽数字：倒计时每秒跳动时不会左右抖
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  /// 类型标签：普通作业主色浅底，高风险琥珀底带锁
  Widget _buildTypeTag(TaskType type) {
    final isSafe = !type.highRisk;
    final fg = isSafe ? AppColors.primary : _riskColor;
    final bg = isSafe ? _safeBg : _riskBg;

    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
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
              fontSize: 11,
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
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.inbox_rounded,
                size: 32,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无待办数据',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '点「读取作业」进入学习通，手动点到「课程 → 作业」页面，\n'
              '再点右上角的提取按钮；提取结果会自动保存在本地。\n'
              '想少找几次课？先到「入口」页把课程存成快捷卡片。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: AppColors.secondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openManualEntry,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('读取作业'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数字平滑滚动（计数从旧值滚到新值，等宽数字保证不晃）
class _AnimatedCount extends StatelessWidget {
  const _AnimatedCount({
    required this.value,
    required this.valueKey,
    this.style,
  });

  final int value;
  final Key valueKey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // begin 仅在首帧生效：首帧直接显示真实值，不做从 0 起跳的动画
      tween: Tween<double>(begin: value.toDouble(), end: value.toDouble()),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) =>
          Text('${animated.round()}', key: valueKey, maxLines: 1, style: style),
    );
  }
}

/// 顶部统计卡上的流光：一条极淡的白色光带缓慢斜向扫过
class _CardShimmer extends StatefulWidget {
  const _CardShimmer();

  @override
  State<_CardShimmer> createState() => _CardShimmerState();
}

class _CardShimmerState extends State<_CardShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final dx = -0.4 * width + _controller.value * 1.8 * width;
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: <Widget>[
                  Transform.translate(
                    offset: Offset(dx, 0),
                    child: Transform.rotate(
                      angle: 0.22,
                      child: Container(
                        width: 110,
                        height: height * 1.8,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: <Color>[
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(alpha: 0.14),
                              Colors.white.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// 列表项入场：淡入 + 轻微上移（无定时器，滚回不会重放）
class _Entrance extends StatelessWidget {
  const _Entrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = index.clamp(0, 8) * 0.055;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 340),
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, value, inner) {
        final t = value.clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 10),
            child: inner,
          ),
        );
      },
      child: child,
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

  factory _ModelDraft.empty(int id) =>
      _ModelDraft(id: id, name: '', baseUrl: '', model: '', apiKey: '');

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

  LlmModel toModel() =>
      LlmModel(name: name, baseUrl: baseUrl, model: model, apiKey: apiKey);
}
