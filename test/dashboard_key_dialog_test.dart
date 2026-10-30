import 'package:ai_web_reader/core/config/app_config.dart';
import 'package:ai_web_reader/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 默认预设是 2 个模型 → 8 个输入框，视口要够高才不会被裁掉
  Future<void> pumpDashboard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await AppConfig.init();
    await tester.pumpWidget(const MaterialApp(home: DashboardPage()));
    await tester.pump();
  }

  testWidgets('模型设置弹窗：动态列表、可编辑、保存后落库', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.text('模型设置'), findsOneWidget);
    expect(find.text('模型 1'), findsOneWidget);
    expect(find.text('模型 2'), findsOneWidget);
    expect(find.text('添加新模型'), findsOneWidget);

    // 每个模型卡片 4 个输入框：名称 / BaseUrl / Model / API Key
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(8));

    // 只给第一个模型填 Key，其余保持原样
    await tester.enterText(fields.at(3), 'sk-deepseek-test-123456');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final models = AppConfig.getLlmModels();
    expect(models, hasLength(2));
    expect(models[0].name, 'DeepSeek');
    expect(models[0].apiKey, 'sk-deepseek-test-123456');
    expect(models[1].name, '通义千问');
    expect(models[1].apiKey, isEmpty);
    expect(AppConfig.usableLlmModels, hasLength(1));

    expect(find.text('模型设置'), findsNothing);
    expect(tester.takeException(), isNull);

    // 重新打开：输入框应回显已保存的值
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    final reopened = find.byType(TextField);
    expect(
      tester.widget<TextField>(reopened.at(3)).controller?.text,
      'sk-deepseek-test-123456',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加新模型：列表多出一张空卡片，空卡片保存时被丢弃', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加新模型'));
    await tester.pumpAndSettle();

    expect(find.text('模型 3'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(12));

    // 新卡片一个字都没填 → 保存时应被过滤掉
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(AppConfig.getLlmModels(), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('上下移动：交换优先级顺序，边界按钮置灰，已输入文字不丢', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    // 注意：要取 IconButton 本身才能读 onPressed，byIcon 拿到的是 Icon
    final upButtons = find.widgetWithIcon(IconButton, Icons.arrow_upward);
    final downButtons = find.widgetWithIcon(IconButton, Icons.arrow_downward);
    expect(upButtons, findsNWidgets(2));

    // 边界控制：首项不能上移，末项不能下移（onPressed == null 即置灰禁用）
    expect(tester.widget<IconButton>(upButtons.first).onPressed, isNull);
    expect(tester.widget<IconButton>(downButtons.last).onPressed, isNull);
    expect(tester.widget<IconButton>(upButtons.last).onPressed, isNotNull);
    expect(tester.widget<IconButton>(downButtons.first).onPressed, isNotNull);

    // 改第一张卡片的名称，验证交换后文字跟着卡片走
    await tester.enterText(find.byType(TextField).at(0), '主模型-改名');
    await tester.pump();

    // 第二张（千问）上移 → 变成第一位
    await tester.tap(upButtons.at(1));
    await tester.pumpAndSettle();

    expect(find.text('主模型-改名'), findsOneWidget, reason: '重排后已输入文字不能丢');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final models = AppConfig.getLlmModels();
    expect(models, hasLength(2));
    expect(models[0].name, '通义千问', reason: '千问应被移到第一位');
    expect(models[1].name, '主模型-改名');
    expect(tester.takeException(), isNull);
  });

  testWidgets('下移按钮同样生效，可把首位模型降到末位', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    // 第一张卡片下移
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final models = AppConfig.getLlmModels();
    expect(models[0].name, '通义千问');
    expect(models[1].name, 'DeepSeek');
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除模型：红色删除按钮移除对应卡片', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('模型 2'), findsOneWidget);

    // 删除第二张卡片
    await tester.tap(find.byIcon(Icons.delete_outline).at(1));
    await tester.pumpAndSettle();
    expect(find.text('模型 2'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(4));

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(AppConfig.getLlmModels(), hasLength(1));
    expect(AppConfig.getLlmModels().single.name, 'DeepSeek');
    expect(tester.takeException(), isNull);
  });
}
