import 'package:ai_web_reader/data/services/scanner_service.dart';
import 'package:ai_web_reader/data/services/task_store.dart';
import 'package:ai_web_reader/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 测试用固定数据（生产环境走 ScannerService 真实扫描）
CourseTask _task(
  String course,
  String title,
  TaskType type,
  Duration left, {
  String status = '未交',
}) {
  return CourseTask(
    title: title,
    courseName: course,
    type: type,
    deadline: DateTime.now().add(left),
    url: 'https://mooc1.chaoxing.com/mock',
    status: status,
  );
}

List<CourseGroup> _previewCourses() {
  return <CourseGroup>[
    CourseGroup(
      name: '高等数学 A',
      teacher: '共 2 份任务',
      accent: const Color(0xFF3F6BE0),
      tasks: <CourseTask>[
        _task(
          '高等数学 A',
          '第 3 章 极限 课后习题',
          TaskType.homework,
          const Duration(hours: 18),
        ),
        _task(
          '高等数学 A',
          'MATLAB 数值实验（视频实践）',
          TaskType.video,
          const Duration(hours: 30),
        ),
      ],
    ),
    CourseGroup(
      name: '数据结构',
      teacher: '共 2 份任务',
      accent: const Color(0xFF7C4DFF),
      tasks: <CourseTask>[
        _task('数据结构', '期中考试（机考）', TaskType.exam, const Duration(hours: 40)),
        _task(
          '数据结构',
          '第 4 章 树与二叉树 作业',
          TaskType.homework,
          const Duration(hours: 60),
        ),
      ],
    ),
    CourseGroup(
      name: '线性代数',
      teacher: '共 0 份任务',
      accent: const Color(0xFF546E7A),
      tasks: const <CourseTask>[],
    ),
  ];
}

void main() {
  /// 顶部统计卡里的数字（按 key 取值，避免和卡片上的徽章数字混淆）
  String statValue(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

  Future<void> pumpDashboard(
    WidgetTester tester, {
    List<CourseGroup>? courses,
    List<CourseRef>? shortcuts,
  }) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(
          previewCourses: courses ?? _previewCourses(),
          previewShortcuts: shortcuts,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('按课程视图：渲染课程网格卡片与待办徽章', (tester) async {
    await pumpDashboard(tester);

    expect(find.text('高等数学 A'), findsOneWidget);
    expect(find.text('数据结构'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget); // 无作业课程也显示

    // 两门课各 2 份待办：徽章挂在各自的卡片上
    expect(
      find.byKey(const ValueKey<String>('course-badge-高等数学 A')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('course-badge-数据结构')),
      findsOneWidget,
    );
    // 线性代数没有待办 → 不显示徽章
    expect(
      find.byKey(const ValueKey<String>('course-badge-线性代数')),
      findsNothing,
    );

    // 顶部统计卡：总待办 4、紧急 1（18h）、高风险 2（视频实践 + 考试）
    expect(statValue(tester, 'stat-pending'), '4');
    expect(statValue(tester, 'stat-urgent'), '1');
    expect(statValue(tester, 'stat-risk'), '2');

    // 顶部：重新提取按钮 + 模型设置
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    // 模型胶囊在顶部看板下方
    expect(find.byKey(const ValueKey<String>('model-chip')), findsOneWidget);
  });

  testWidgets('切换按作业视图：隐藏无作业课程，紧急的在前', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.text('作业'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('线性代数'), findsNothing);

    const earliest = '第 3 章 极限 课后习题'; // 18h
    const latest = '第 4 章 树与二叉树 作业'; // 60h
    expect(
      tester.getTopLeft(find.text(earliest)).dy,
      lessThan(tester.getTopLeft(find.text(latest)).dy),
    );
  });

  testWidgets('点课程卡片弹出 BottomSheet，按截止倒序', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.text('数据结构'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('按截止时间倒序排列'), findsOneWidget);
    expect(find.text('2 份待办'), findsOneWidget);

    const later = '第 4 章 树与二叉树 作业'; // 60h
    const earlier = '期中考试（机考）'; // 40h
    expect(
      tester.getTopLeft(find.text(later)).dy,
      lessThan(tester.getTopLeft(find.text(earlier)).dy),
    );

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('按截止时间倒序排列'), findsNothing);
  });

  testWidgets('高风险任务带锁，点击弹出警告，取消后不跳转', (tester) async {
    await pumpDashboard(tester);
    await tester.tap(find.text('作业'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.lock_rounded), findsWidgets);

    await tester.tap(find.text('期中考试（机考）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('高风险任务'), findsOneWidget);
    expect(find.textContaining('禁止在内置 WebView 加载'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('高风险任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课程入口视图：渲染快捷卡片，有待办的排在前面', (tester) async {
    final shortcuts = <CourseRef>[
      const CourseRef(
        courseName: '线性代数',
        courseId: '1',
        classId: '11',
        cpi: '111',
      ),
      const CourseRef(
        courseName: '高等数学 A',
        courseId: '2',
        classId: '22',
        cpi: '222',
        enc: 'abc',
        homeUrl: 'https://mooc1.chaoxing.com/mooc2/work/list?enc=abc',
      ),
    ];

    await pumpDashboard(tester, shortcuts: shortcuts);
    await tester.tap(find.text('入口'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('高等数学 A'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget);
    // 两列网格：高等数学 A 有 2 份待办，排在第一行第一列
    expect(
      tester.getTopLeft(find.text('高等数学 A')).dx,
      lessThan(tester.getTopLeft(find.text('线性代数')).dx),
    );
    // 有 enc 的直接说「直达作业列表」，没有的只能进课程主页
    expect(find.text('直达作业列表'), findsOneWidget);
    expect(find.text('打开课程主页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有课程入口时显示引导，而不是空作业态', (tester) async {
    await pumpDashboard(tester, shortcuts: const <CourseRef>[]);
    await tester.tap(find.text('入口'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('还没有课程入口'), findsOneWidget);
    expect(find.text('暂无待办数据'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('总待办只数「未交」：已交/待批阅的不进计数', (tester) async {
    final courses = <CourseGroup>[
      CourseGroup(
        name: '英语四六级',
        teacher: '共 5 份任务',
        accent: const Color(0xFF3F6BE0),
        tasks: <CourseTask>[
          for (var i = 1; i <= 4; i++)
            _task(
              '英语四六级',
              '作业$i',
              TaskType.homework,
              const Duration(hours: 20),
            ),
          // 第 5 条已交：网页上不算未交，看板也不该 +1
          _task(
            '英语四六级',
            '作业5（已交）',
            TaskType.homework,
            const Duration(hours: 20),
            status: '已交',
          ),
        ],
      ),
    ];

    await pumpDashboard(tester, courses: courses);

    expect(statValue(tester, 'stat-pending'), '4');
    expect(statValue(tester, 'stat-urgent'), '4');
    expect(tester.takeException(), isNull);
  });

  testWidgets('过期但仍未交的作业照样计入总待办（和网页的「未交」数对齐）', (tester) async {
    final courses = <CourseGroup>[
      CourseGroup(
        name: '英语四六级',
        teacher: '共 2 份任务',
        accent: const Color(0xFF3F6BE0),
        tasks: <CourseTask>[
          _task('英语四六级', '作业1', TaskType.homework, const Duration(hours: 20)),
          _task(
            '英语四六级',
            '作业2（已截止但仍未交）',
            TaskType.homework,
            const Duration(hours: -30),
          ),
        ],
      ),
    ];

    await pumpDashboard(tester, courses: courses);

    expect(statValue(tester, 'stat-pending'), '2');
    expect(statValue(tester, 'stat-urgent'), '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('左滑卡片：作业立刻从看板消失，缓存同步覆盖', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpDashboard(tester);

    await tester.tap(find.text('作业'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(statValue(tester, 'stat-pending'), '4');
    const target = '第 3 章 极限 课后习题';

    // 往左滑过阈值 → Dismissible 收起 → 回调里删数据
    await tester.drag(find.text(target), const Offset(-500, 0));
    // Dismissible 收起动画结束后才回调 onDismissed，需要多推几帧
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.text(target), findsNothing);
    expect(statValue(tester, 'stat-pending'), '3');
    // 给了「撤销」的机会
    expect(find.textContaining('已移除'), findsOneWidget);

    // 已经落盘：杀进程重进也不会再出现
    final saved = await TaskStore.load();
    expect(saved.any((e) => e.title == target), isFalse);
    expect(tester.takeException(), isNull);
  });
}
