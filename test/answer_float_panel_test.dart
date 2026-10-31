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

/// 面板底部那个操作按钮
Finder actionButton() => find.byType(FilledButton);

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

  testWidgets('idle 态：文案为「提取题目并请求 AI」且可点击', (tester) async {
    await _pump(tester, stage: SolvingStage.idle);

    expect(find.text('提取题目并请求 AI'), findsOneWidget);
    await tester.tap(actionButton());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('thinking 态：按钮禁用，文案为「执行中...」', (tester) async {
    await _pump(tester, stage: SolvingStage.thinking);

    expect(find.text('执行中...'), findsOneWidget);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNull);
  });

  testWidgets('completed 态：按钮可点击，文案为「重新分析」', (tester) async {
    await _pump(tester, stage: SolvingStage.completed);

    expect(find.text('重新分析'), findsOneWidget);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNotNull);
  });

  testWidgets('error 态：按钮可点击，文案为「重试」', (tester) async {
    await _pump(tester, stage: SolvingStage.error);

    expect(find.text('重试'), findsOneWidget);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNotNull);
  });

  testWidgets('没探测到题目时按钮禁用', (tester) async {
    await _pump(tester, stage: SolvingStage.idle, enabled: false);
    expect(tester.widget<FilledButton>(actionButton()).onPressed, isNull);
    // 灰按钮要写明原因，否则用户不知道先去作业列表页
    expect(find.textContaining('当前页没有题目'), findsOneWidget);
  });

  testWidgets('没有答案时面板默认只占三成高度', (tester) async {
    await _pump(tester, stage: SolvingStage.idle);

    final height = tester.getSize(find.byKey(const ValueKey<String>('panel'))).height;
    // 容器高 800：无答案默认 0.30 → 约 240；有答案才是 0.45 → 约 360
    expect(height, lessThan(300));
    expect(height, greaterThan(200));
  });

  testWidgets('有答案：渲染卡片，点复制写入剪贴板并提示', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    expect(find.text('参考答案 2 条'), findsOneWidget);
    expect(find.text('第 1 题 · 单选'), findsOneWidget);
    expect(find.text('第 2 题 · 填空'), findsOneWidget);

    await tester.tap(find.text('复制').first);
    await tester.pump();

    expect(_clipboard, 'B');
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('复制全部：把每条拼成一段文本', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    await tester.tap(find.byIcon(Icons.copy_all_outlined));
    await tester.pump();

    expect(_clipboard, contains('第 1 题 · 单选\nB'));
    expect(_clipboard, contains('第 2 题 · 填空\n北京、上海'));
    expect(find.text('已复制全部 2 条'), findsOneWidget);
  });

  testWidgets('最小化变成小球，点小球再展开', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    await tester.tap(find.byIcon(Icons.minimize));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('panel-ball')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('panel-ball')));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('panel-ball')), findsNothing);
    expect(find.byKey(const ValueKey<String>('panel')), findsOneWidget);
    // 展开后答案还在
    expect(find.text('第 1 题 · 单选'), findsOneWidget);
  });

  testWidgets('拖把手：往上拖变高，往下拖变矮', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);
    await tester.pump();

    final panel = find.byKey(const ValueKey<String>('panel'));
    final before = tester.getSize(panel).height;

    await tester.drag(
      find.byKey(const ValueKey<String>('panel-handle')),
      const Offset(0, -150),
    );
    await tester.pump();
    final taller = tester.getSize(panel).height;

    await tester.drag(
      find.byKey(const ValueKey<String>('panel-handle')),
      const Offset(0, 260),
    );
    await tester.pump();
    final shorter = tester.getSize(panel).height;

    expect(taller, greaterThan(before));
    expect(shorter, lessThan(taller));
    // 有下限，不会被拖到消失
    expect(shorter, greaterThanOrEqualTo(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('小球可上下拖动', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);
    await tester.tap(find.byIcon(Icons.minimize));
    await tester.pump();

    final ball = find.byKey(const ValueKey<String>('panel-ball'));
    final before = tester.getTopLeft(ball).dy;

    await tester.drag(ball, const Offset(0, -200));
    await tester.pump();

    expect(tester.getTopLeft(ball).dy, lessThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有答案时展示日志与引导，而不是答案列表', (tester) async {
    final controller = await _pump(tester, stage: SolvingStage.idle);
    controller.addLog('🔒 页面指纹一致 {"fields":34} —— 网页未被修改');
    await tester.pump();

    // 出现在两处：日志列表一条 + 底部单行摘要一条
    expect(find.textContaining('页面指纹一致'), findsNWidgets(2));
    expect(find.text('复制'), findsNothing);
  });

  testWidgets('双模式：默认详情铺开，切列表后只列题号，答案收起', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);

    // 默认详情模式：答案直接铺开
    expect(find.byKey(const ValueKey<String>('mode-detail')), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('北京、上海'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('mode-list')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 列表模式：题号在，答案收起
    expect(find.text('第 1 题 · 单选'), findsOneWidget);
    expect(find.text('第 2 题 · 填空'), findsOneWidget);
    expect(find.text('B'), findsNothing);
    expect(find.text('北京、上海'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNWidgets(2));
  });

  testWidgets('列表模式：点题号手风琴展开，再点收起', (tester) async {
    await _pump(tester, stage: SolvingStage.completed, answers: _answers);
    await tester.tap(find.byKey(const ValueKey<String>('mode-list')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('第 2 题 · 填空'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 只展开第 2 题
    expect(find.text('北京、上海'), findsOneWidget);
    expect(find.text('B'), findsNothing);

    // 每行标题栏都能直接复制（不用先展开、也不用滚到底）
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('answer-row-2')),
        matching: find.text('复制'),
      ),
    );
    await tester.pump();
    expect(_clipboard, '北京、上海');

    await tester.tap(find.text('第 2 题 · 填空'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('北京、上海'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换一批答案后自动回到展开态并清空手风琴', (tester) async {
    final controller = await _pump(
      tester,
      stage: SolvingStage.completed,
      answers: _answers,
    );
    await tester.tap(find.byKey(const ValueKey<String>('mode-list')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('第 1 题 · 单选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('B'), findsOneWidget);

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
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('参考答案 1 条'), findsOneWidget);
    // 手风琴已清空：列表模式下新答案也是收起的
    expect(find.text('新答案'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
