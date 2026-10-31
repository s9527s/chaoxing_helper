import 'package:flutter/material.dart';

import 'core/config/app_config.dart';
import 'ui/pages/splash_gate_page.dart';
import 'ui/theme/app_theme.dart';

/// 全局 Navigator Key：便于在非 Widget 上下文（如拦截器、定时任务）中跳转。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  // 1) 必须先初始化 Binding，之后才能用 MethodChannel / 插件（SharedPreferences 依赖它）
  WidgetsFlutterBinding.ensureInitialized();

  // 2) 再读本地配置。init 失败绝不允许阻断 runApp，否则就是永久白屏
  try {
    await AppConfig.init();
  } catch (e, stack) {
    debugPrint('[main] AppConfig.init 失败，使用空 Key 继续启动: $e\n$stack');
  }

  // 3) 最后才挂载 App
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '学习通助手',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const SplashGatePage(),
    );
  }
}
