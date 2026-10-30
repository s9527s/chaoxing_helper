import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/network/cookie_sync_helper.dart';
import 'dashboard_page.dart';

/// 学习通登录页：内嵌 passport2 登录，登录成功（落地到个人空间）后抓取 Cookie
/// 并进入 [DashboardPage]。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static final WebUri _loginUrl = WebUri('https://passport2.chaoxing.com/login');

  /// 判定登录成功的落地页特征。
  static const List<String> _successUrlHints = <String>[
    'i.chaoxing.com',
    'space/index',
  ];

  InAppWebViewController? _webViewController;

  double _progress = 0;
  bool _isSyncing = false;
  bool _hasNavigated = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录学习通'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '刷新页面',
            onPressed: _reloadPage,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: _loginUrl),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              thirdPartyCookiesEnabled: true,
              sharedCookiesEnabled: true,
              useShouldOverrideUrlLoading: false,
              useHybridComposition: true,
              supportZoom: false,
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
            },
            onProgressChanged: (controller, progress) {
              if (!mounted) return;
              setState(() => _progress = progress / 100);
            },
            onLoadStop: (controller, url) {
              _handleUrlChanged(url);
            },
            onUpdateVisitedHistory: (controller, url, isReload) {
              _handleUrlChanged(url);
            },
          ),
          if (_progress < 1)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(value: _progress, minHeight: 2),
            ),
          if (_isSyncing)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 20,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('正在同步登录状态…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _reloadPage() async {
    await _webViewController?.reload();
  }

  /// 监听 URL 变化：命中个人空间即认为登录成功。
  Future<void> _handleUrlChanged(WebUri? url) async {
    if (url == null || _isSyncing || _hasNavigated) return;

    final current = url.toString();
    final hit = _successUrlHints.any((hint) => current.contains(hint));
    if (!hit) return;

    _hasNavigated = true;
    if (mounted) setState(() => _isSyncing = true);

    try {
      final cookieHeader = await CookieSyncHelper.instance.syncFromWebView();
      if (!mounted) return;

      if (cookieHeader.isEmpty) {
        _hasNavigated = false;
        setState(() => _isSyncing = false);
        _showMessage('未获取到登录 Cookie，请重试或手动完成登录');
        return;
      }

      final fieldsOk = await CookieSyncHelper.instance.hasRequiredAuthFields();
      if (!mounted) return;
      if (!fieldsOk) {
        // Cookie 已保存，但关键字段缺失时提示用户，仍允许进入（可由页面自助刷新登录）
        _showMessage('登录 Cookie 不完整（缺少 UID/_d/vc3），可能需重新登录');
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const DashboardPage()),
      );
    } catch (e) {
      _hasNavigated = false;
      if (mounted) {
        setState(() => _isSyncing = false);
        _showMessage('登录状态保存失败：$e');
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
