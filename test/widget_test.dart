import 'package:ai_web_reader/core/config/app_config.dart';
import 'package:ai_web_reader/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('看板首帧不再自动扫描，直接显示空状态与提取引导', (WidgetTester tester) async {
    // 后台自动扫描已移除：进页面时不会发起任何网络/WebView 请求，
    // 未导入数据时就是空状态。
    // 预热 SharedPreferences，让 TaskStore 的缓存读取在测试内能立刻完成
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppConfig.init();

    await tester.pumpWidget(const MaterialApp(home: DashboardPage()));
    await tester.pump();
    await tester.pump();

    expect(find.text('作业看板'), findsOneWidget);
    expect(find.text('课程'), findsOneWidget); // 分段控件
    expect(find.text('作业'), findsOneWidget);
    expect(find.text('入口'), findsOneWidget); // 课程快捷入口
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    // 空状态引导：标题 + 「读取作业」按钮（空态按钮与悬浮按钮各一个）
    expect(find.text('暂无待办数据'), findsOneWidget);
    expect(find.text('读取作业'), findsNWidgets(2));
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

    await tester.pumpWidget(MaterialApp(home: DashboardPage(previewCourses: courses)));
    await tester.pump();
    await tester.pump();

    expect(find.text('测试课程'), findsOneWidget);
    expect(find.text('测试作业'), findsNothing); // 课程视图只列课程
  });
}
