import 'package:ai_web_reader/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('看板首帧不再自动扫描，直接显示空状态与提取引导', (WidgetTester tester) async {
    // 后台自动扫描已移除：进页面时不会发起任何网络/WebView 请求，
    // 未导入数据时就是空状态。
    await tester.pumpWidget(const MaterialApp(home: DashboardPage()));
    await tester.pump();

    expect(find.text('作业'), findsOneWidget);
    expect(find.text('按课程视图'), findsOneWidget);
    expect(find.text('按作业视图'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    // 空状态引导（含一个「去提取作业」按钮和右下角悬浮入口）
    expect(find.text('还没有作业数据'), findsOneWidget);
    expect(find.text('去提取作业'), findsOneWidget);
    expect(find.text('手动进入作业页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('注入数据后能渲染课程卡片', (WidgetTester tester) async {
    final courses = <CourseGroup>[
      CourseGroup(
        name: '测试课程',
        teacher: '共 1 份任务',
        accent: const Color(0xFF3F6BE0),
        tasks: <CourseTask>[
          CourseTask(
            title: '测试作业',
            courseName: '测试课程',
            type: TaskType.homework,
            deadline: DateTime.now().add(const Duration(hours: 10)),
            url: 'https://mooc1.chaoxing.com/mock',
          ),
        ],
      ),
    ];

    await tester.pumpWidget(MaterialApp(home: DashboardPage(debugCourses: courses)));
    await tester.pump();

    expect(find.text('测试课程'), findsOneWidget);
    expect(find.text('测试作业'), findsNothing); // 课程视图只列课程
  });
}
