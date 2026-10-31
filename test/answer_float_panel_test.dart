import 'package:ai_web_reader/ui/widgets/answer_float_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const List<AnswerEntry> _answers = <AnswerEntry>[
  AnswerEntry(index: 1, typeLabel: '单选', answer: 'B', stem: '1 + 1 = ?'),
  AnswerEntry(
    index: 2,
    typeLabel: '填空',
    answer: '北京、上海',
    stem: '中国的首都是哪里？',
  ),
];

/// 测试里没有真的剪贴板，用平台通道 mock 接住 Clipboard.setData
String _clipboard = '';

Future<SolvingProgressController> _pump(
  WidgetTester tester, {
  required SolvingStage stage,
  List<AnswerEntry> answers = const <AnswerEntry>[],
  bool enabled = true,
}) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = SolvingProgressController()..setStage(stage);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 800,
          child: AnswerFloatPanel(
            controller: controller,
            answers: answers,
            enabled: enabled,
            onStartPressed: () {},
          ),
        ),
      ),
    ),
  );
  return controller;
}

/// 面板头部的「开始分析 / 重新分析」胶囊
Finder actionButton() => find.byType(FilledButton);

/// 某个题号胶囊（AnimatedContainer 上带着选中态底色）
AnimatedContainer chipOf(WidgetTester tester, int index) =>
    tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(ValueKey<String>('index-chip-$index')),
        matching: find.byType(AnimatedContainer),
      ),
    );

bool chipSelected(WidgetTester tester, int index) {
  final decoration = chipOf(tester, index).decoration! as BoxDecoration;
  return decoration.color == const Color(0xFF4F46E5);
}

void main() {
  setUp(() {
    _clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            _clipboard = (call.arguments['text'] as String?) ?? '';
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('idle 态：文案为「开始分析」且可点击', (tester) async {
    await _pump(tester, stage: SolvingStage.idle);

    expect(find.text('开始分析'), findsOneWidget);
    await tester.tap(actionButton());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('thinking 态：按钮禁用，文案为「执行中」', (tester) async {
    await _pump(tester, stage: SolvingStage.thinking);

    expect(find.text('执行中'), findsOneWidget);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNull);
  });

  testWidgets('completed 态：按钮可点击，文案为「重新分析」，状态胶囊「已就绪」', (tester) async {
    await _pump(tester, stage: SolvingStage.completed);

    expect(find.text('重新分析'), findsOneWidget);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNotNull);
    expect(find.text('已就绪'), findsOneWidget);
  });

  testWidgets('error 态：按钮可点击，文案为「重试」', (tester) async {
    await _pump(tester, stage: SolvingStage.error);

    expect(find.text('重试'), findsOneWidget);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNotNull);
    expect(find.text('分析失败'), findsOneWidget);
  });

  testWidgets('没探测到题目时按钮禁用', (tester) async {
    await _pump(tester, stage: SolvingStage.idle, enabled: false);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNull);
    // 胶囊写不下长句，原因放在正文引导里
    expect(find.textContaining('当前页没有题目'), findsOneWidget);
  });

  testWidgets('没有答案时面板比有答案时矮，不压住作业列表', (tester) async {
    await _pump(tester, stage: SolvingStage.idle);
    final emptyHeight = tester
        .getSize(find.byKey(const ValueKey<String>('panel')))
        .height;

    final controller = SolvingProgressController()
      ..setStage(SolvingStage.completed);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: AnswerFloatPanel(
              controller: controller,
              answers: _answers,
              onStartPressed: () {},
            ),
          ),
        ),
      ),
    );
    // 高度是动画过渡的，等它走完再量
    await tester.pump(const Duration(milliseconds: 300));
    final filledHeight = tester
        .getSize(find.byKey(const ValueKey<String>('panel')))
        .height;

    // 容器高 800：无答案 0.32 → 256（但受最小可用高度 280 兜底），有答案 0.55 → 440
    expect(emptyHeight, closeTo(280, 0.01));
    expect(emptyHeight, lessThan(filledHeight));
    expect(filledHeight, closeTo(440, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('题号栏：每题一个胶囊，默认选中第 1 题并只显示它的答案', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    expect(find.byKey(const ValueKey<String>('index-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('index-chip-1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('index-chip-2')), findsOneWidget);

    // 默认第 1 题：胶囊高亮，卡片只出第 1 题的答案
    expect(chipSelected(tester, 1), isTrue);
    expect(chipSelected(tester, 2), isFalse);
    expect(find.text('第 1 题'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('北京、上海'), findsNothing);
  });

  testWidgets('点题号 2：胶囊高亮切换，卡片换成第 2 题答案（带淡入淡出）', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    await tester.tap(find.byKey(const ValueKey<String>('index-chip-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(chipSelected(tester, 2), isTrue);
    expect(chipSelected(tester, 1), isFalse);
    expect(find.text('第 2 题'), findsOneWidget);
    expect(find.text('北京、上海'), findsOneWidget);
    expect(find.text('B'), findsNothing);

    // 再点回第 1 题
    await tester.tap(find.byKey(const ValueKey<String>('index-chip-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(chipSelected(tester, 1), isTrue);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('北京、上海'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情卡复制按钮只复制当前这一题，并变成绿色「已复制」', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    await tester.tap(find.byKey(const ValueKey<String>('index-chip-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('copy-2')));
    await tester.pump();

    expect(_clipboard, '北京、上海');
    expect(find.text('已复制'), findsOneWidget);

    // 1.6s 后自动回到「复制」
    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复制全部：把每条拼成一段文本', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    await tester.tap(find.byKey(const ValueKey<String>('copy-all')));
    await tester.pump();

    expect(_clipboard, contains('第 1 题 · 单选\nB'));
    expect(_clipboard, contains('第 2 题 · 填空\n北京、上海'));
    expect(find.text('已复制全部 2 条'), findsOneWidget);
  });

  testWidgets('最小化变成小球，点小球再展开', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    await tester.tap(find.byKey(const ValueKey<String>('panel-minimize')));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('panel-ball')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('panel-ball')));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('panel-ball')), findsNothing);
    expect(find.byKey(const ValueKey<String>('panel')), findsOneWidget);
    // 展开后答案还在
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('拖把手：往上拖变高，往下拖变矮', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);
    await tester.pump();

    final panel = find.byKey(const ValueKey<String>('panel'));
    final handle = find.byKey(const ValueKey<String>('panel-handle'));
    final before = tester.getSize(panel).height;

    // 逐步移动（单步大位移在测试里不会被垂直拖拽识别器接住）
    Future<void> dragBy(double dy) async {
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      var moved = 0.0;
      while (moved < dy.abs()) {
        final step = (dy.abs() - moved).clamp(0.0, 40.0);
        await gesture.moveBy(Offset(0, dy.isNegative ? -step : step));
        moved += step;
        await tester.pump();
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 250));
    }

    await dragBy(-150);
    final taller = tester.getSize(panel).height;

    await dragBy(260);
    final shorter = tester.getSize(panel).height;

    expect(taller, greaterThan(before));
    expect(shorter, lessThan(taller));
    // 有下限，不会被拖到消失
    expect(shorter, greaterThanOrEqualTo(280));
    expect(tester.takeException(), isNull);
  });

  testWidgets('小球可上下拖动', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);
    await tester.tap(find.byKey(const ValueKey<String>('panel-minimize')));
    await tester.pump();

    final ball = find.byKey(const ValueKey<String>('panel-ball'));
    final before = tester.getTopLeft(ball).dy;

    await tester.drag(ball, const Offset(0, -200));
    await tester.pump();

    expect(tester.getTopLeft(ball).dy, lessThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('日志默认折叠，点状态胶囊才展开', (tester) async {
    final controller = await _pump(tester, stage: SolvingStage.idle);
    controller.addLog('🔒 页面指纹一致 {"fields":34} —— 网页未被修改');
    await tester.pump();

    // 默认不显示日志，只留引导文案
    expect(find.byKey(const ValueKey<String>('log-list')), findsNothing);
    expect(find.text('待开始'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('index-bar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('status-pill')));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('log-list')), findsOneWidget);
    expect(find.textContaining('页面指纹一致'), findsOneWidget);

    // 再点一次收起
    await tester.tap(find.byKey(const ValueKey<String>('status-pill')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('log-list')), findsNothing);
  });

  testWidgets('题目很多时题号胶囊横向滚动，不溢出', (tester) async {
    final many = <AnswerEntry>[
      for (var i = 1; i <= 12; i++)
        AnswerEntry(index: i, typeLabel: '单选', answer: '答案 $i'),
    ];
    await _pump(tester, stage: SolvingStage.completed, answers: many);

    // 题号栏是单行横向滚动：高度固定 32
    final barHeight = tester
        .getSize(find.byKey(const ValueKey<String>('index-bar')))
        .height;
    expect(barHeight, 32);

    // 末尾的题号要滚一下才进入可见区（懒加载）
    await tester.drag(
      find.byKey(const ValueKey<String>('index-bar')),
      const Offset(-600, 0),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('index-chip-12')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('答案已把题干抄进去时，不再重复显示一遍题干', (tester) async {
    const echo = <AnswerEntry>[
      AnswerEntry(
        index: 1,
        typeLabel: '简答',
        stem: '中国的首都是哪里？',
        answer: '中国的首都是哪里？ 中国的首都是北京。',
      ),
    ];
    await _pump(tester, stage: SolvingStage.completed, answers: echo);

    // 题干只出现一次（在答案里），不会在卡片顶部再铺一段
    expect(find.text('中国的首都是哪里？'), findsNothing);
    expect(find.text('中国的首都是哪里？ 中国的首都是北京。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换一批答案后自动回到第 1 题', (tester) async {
    final controller = await _pump(
      tester,
      stage: SolvingStage.completed,
      answers: _answers,
    );
    await tester.tap(find.byKey(const ValueKey<String>('index-chip-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('北京、上海'), findsOneWidget);

    // 页面把 answers 换成了新一批
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: AnswerFloatPanel(
              controller: controller,
              answers: const <AnswerEntry>[
                AnswerEntry(index: 1, typeLabel: '简答', answer: '新答案'),
              ],
              onStartPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('AI 阅读助手'), findsOneWidget);
    expect(find.text('新答案'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('index-chip-2')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
