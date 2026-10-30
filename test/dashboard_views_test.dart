import 'package:ai_web_reader/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 测试用固定数据（生产环境走 ScannerService 真实扫描）
CourseTask _task(
  String course,
  String title,
  TaskType type,
  Duration left,
) {
  return CourseTask(
    title: title,
    courseName: course,
    type: type,
    deadline: DateTime.now().add(left),
    url: 'https://mooc1.chaoxing.com/mock',
  );
}

List<CourseGroup> _debugCourses() {
  return <CourseGroup>[
    CourseGroup(
      name: '高等数学 A',
      teacher: '共 2 份任务',
      accent: const Color(0xFF3F6BE0),
      tasks: <CourseTask>[
        _task('高等数学 A', '第 3 章 极限 课后习题', TaskType.homework, const Duration(hours: 18)),
        _task('高等数学 A', 'MATLAB 数值实验（视频实践）', TaskType.video, const Duration(hours: 30)),
      ],
    ),
    CourseGroup(
      name: '数据结构',
      teacher: '共 2 份任务',
      accent: const Color(0xFF7C4DFF),
      tasks: <CourseTask>[
        _task('数据结构', '期中考试（机考）', TaskType.exam, const Duration(hours: 40)),
        _task('数据结构', '第 4 章 树与二叉树 作业', TaskType.homework, const Duration(hours: 60)),
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
  Future<void> pumpDashboard(WidgetTester tester, {List<CourseGroup>? courses}) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: DashboardPage(debugCourses: courses ?? _debugCourses())),
    );
    await tester.pump();
  }

  testWidgets('按课程视图：渲染课程卡片与红点数字', (tester) async {
    await pumpDashboard(tester);

    expect(find.text('高等数学 A'), findsOneWidget);
    expect(find.text('数据结构'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget); // 无作业课程也显示
    expect(find.text('2'), findsNWidgets(2)); // 两门课各 2 份
    // 顶部按钮已从「刷新」改为「进页面提取作业」
    expect(find.byIcon(Icons.playlist_add), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('切换按作业视图：隐藏无作业课程，紧急的在前', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.text('按作业视图'));
    await tester.pumpAndSettle();

    expect(find.text('线性代数'), findsNothing);

    const earliest = '第 3 章 极限 课后习题'; // 18h
    const latest = '第 4 章 树与二叉树 作业'; // 60h
    expect(tester.getTopLeft(find.text(earliest)).dy,
        lessThan(tester.getTopLeft(find.text(latest)).dy));
  });

  testWidgets('点课程卡片弹出 BottomSheet，按截止倒序', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.text('数据结构'));
    await tester.pumpAndSettle();

    expect(find.text('按截止时间倒序排列'), findsOneWidget);
    expect(find.text('2 份待办'), findsOneWidget);

    const later = '第 4 章 树与二叉树 作业'; // 60h
    const earlier = '期中考试（机考）'; // 40h
    expect(tester.getTopLeft(find.text(later)).dy,
        lessThan(tester.getTopLeft(find.text(earlier)).dy));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('按截止时间倒序排列'), findsNothing);
  });

  testWidgets('高风险任务带锁，点击弹出警告，取消后不跳转', (tester) async {
    await pumpDashboard(tester);
    await tester.tap(find.text('按作业视图'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.lock_rounded), findsWidgets);

    await tester.tap(find.text('期中考试（机考）'));
    await tester.pumpAndSettle();

    expect(find.text('高风险任务'), findsOneWidget);
    expect(find.textContaining('禁止在内置 WebView 加载'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('高风险任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
