import 'package:ai_web_reader/ui/widgets/solving_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<int> pumpSheet(WidgetTester tester, SolvingStage stage) async {
    var taps = 0;
    final controller = SolvingProgressController()..setStage(stage);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SolvingBottomSheet(
            controller: controller,
            onStartPressed: () => taps++,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    return taps;
  }

  testWidgets('error 态：按钮可点击，文案为「重试」', (tester) async {
    final taps = await pumpSheet(tester, SolvingStage.error);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('执行中断'), findsOneWidget);
    expect(taps, 1, reason: 'error 态点击必须触发 onStartPressed');
  });

  testWidgets('completed 态：按钮可点击，文案为「重新分析」', (tester) async {
    final taps = await pumpSheet(tester, SolvingStage.completed);
    expect(find.text('重新分析'), findsOneWidget);
    expect(taps, 1);
  });

  testWidgets('thinking 态：按钮禁用，文案为「执行中...」', (tester) async {
    final taps = await pumpSheet(tester, SolvingStage.thinking);
    expect(find.text('执行中...'), findsOneWidget);
    expect(taps, 0, reason: '执行中不允许再次触发');
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('idle 态：文案为「提取题目并请求 AI」且可点击', (tester) async {
    final taps = await pumpSheet(tester, SolvingStage.idle);
    expect(find.text('提取题目并请求 AI'), findsOneWidget);
    expect(taps, 1);
  });
}
