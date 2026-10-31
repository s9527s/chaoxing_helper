import 'package:flutter/material.dart';

import '../../core/network/cookie_sync_helper.dart';
import 'dashboard_page.dart';
import 'login_page.dart';

/// 启动网关页：校验本地登录态，决定进入首页还是登录页。
///
/// 导航纪律（避免 `_dependents.isEmpty` 断言 / 白屏）：
/// 1. 绝不在 build / initState 里直接 Navigator；
/// 2. 只在首帧之后（addPostFrameCallback）触发一次异步判定；
/// 3. 用 [_navigated] 保证 pushReplacement 只执行一次；
/// 4. 异步等待有超时兜底，任何异常都降级到登录页，不让用户卡在启动页。
class SplashGatePage extends StatefulWidget {
  const SplashGatePage({super.key});

  @override
  State<SplashGatePage> createState() => _SplashGatePageState();
}

class _SplashGatePageState extends State<SplashGatePage> {
  /// 会话校验最长等待，超时直接降级到登录页
  static const Duration _sessionCheckTimeout = Duration(seconds: 10);

  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    // 首帧渲染完成后再发起异步校验，绝不在 initState 里直接跳转
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
    });
  }

  Future<void> _bootstrap() async {
    // 已经跳转过 / 页面已销毁，直接退出，避免二次 pushReplacement
    if (_navigated || !mounted) return;

    bool valid = false;
    try {
      // 纯本地判断（只查 Cookie 字段），启动阶段绝不联网。
      valid = await CookieSyncHelper.instance
          .hasLocalSession()
          .timeout(_sessionCheckTimeout, onTimeout: () => false);
    } catch (e) {
      debugPrint('[SplashGate] 登录态校验失败，降级到登录页: $e');
      valid = false;
    }

    // await 之后必须重新校验 mounted，否则 context 可能已失效
    if (!mounted || _navigated) return;

    _navigated = true;

    try {
      // rootNavigator: true，避免将来嵌套 Navigator 时跳错层
      Navigator.of(context, rootNavigator: true).pushReplacement(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 250),
          pageBuilder: (routeContext, animation, secondaryAnimation) =>
              valid ? const DashboardPage() : const LoginPage(),
          transitionsBuilder: (routeContext, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
    } catch (e, stack) {
      // 导航本身失败时兜底：允许用户手动重试，而不是白屏干等
      debugPrint('[SplashGate] 跳转失败: $e\n$stack');
      _navigated = false;
      if (!mounted) return;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                Icons.school_outlined,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '学习通助手',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 12),
            Text(
              '正在检查登录状态…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
