import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 超星（学习通）Cookie 同步与登录态校验。
///
/// 职责：
/// 1. 从 WebView 的 CookieManager 中聚合 .chaoxing.com 各子域 Cookie，去重拼接为
///    `k1=v1; k2=v2` 形式的请求头字符串；
/// 2. 持久化到 SharedPreferences，供 Dio 复用；
/// 3. 通过一次个人空间请求校验登录态是否仍然有效。
class CookieSyncHelper {
  CookieSyncHelper._();

  static final CookieSyncHelper instance = CookieSyncHelper._();

  // ---------------- 常量 ----------------

  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const String moocReferer = 'https://mooc1.chaoxing.com/';

  /// 个人空间首页：未登录会 302 或返回跳登录的落地页，用来验证会话。
  static const String _sessionProbeUrl = 'https://i.chaoxing.com/base';

  /// 需要聚合 Cookie 的域（按顺序覆盖，后者同名字段优先）。
  static const List<String> _cookieSourceHosts = <String>[
    'https://chaoxing.com',
    'https://mooc1.chaoxing.com',
    'https://mooc1-1.chaoxing.com',
    'https://passport2.chaoxing.com',
    'https://i.chaoxing.com',
  ];

  /// 判定「已登录」必须存在的 Cookie 字段（小写比较）。
  static const List<String> _requiredCookieKeys = <String>['uid', '_d', 'vc3'];

  static const String _prefsKey = 'chaoxing_cookie_header';

  // ---------------- 状态 ----------------

  String? _cachedCookieHeader;

  // ---------------- 读取 / 写入 ----------------

  /// 获取持久化的 Cookie 请求头字符串（空字符串表示尚未登录）。
  Future<String> getCookieHeader({bool forceReload = false}) async {
    if (!forceReload && _cachedCookieHeader != null) {
      return _cachedCookieHeader!;
    }
    final prefs = await SharedPreferences.getInstance();
    _cachedCookieHeader = prefs.getString(_prefsKey) ?? '';
    return _cachedCookieHeader!;
  }

  /// 直接写入 Cookie 请求头字符串并持久化。
  Future<void> saveCookieHeader(String cookieHeader) async {
    final normalized = cookieHeader.trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, normalized);
    }
    _cachedCookieHeader = normalized;
  }

  /// 从 WebView 的 CookieManager 抓取并持久化 Cookie，返回拼接后的请求头。
  ///
  /// 只抓取 [_cookieSourceHosts] 覆盖的超星域；同名 Cookie 以后抓到的为准。
  Future<String> syncFromWebView() async {
    final merged = <String, String>{};

    for (final host in _cookieSourceHosts) {
      try {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(host),
        );
        for (final cookie in cookies) {
          final name = cookie.name.trim();
          final value = cookie.value?.toString().trim() ?? '';
          if (name.isEmpty || value.isEmpty) continue;
          merged[name] = value;
        }
      } catch (_) {
        // 单个域抓取失败（如平台不支持）不影响整体流程
        continue;
      }
    }

    final header = merged.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');

    if (header.isNotEmpty) {
      await saveCookieHeader(header);
    }
    return header;
  }

  /// 清空本地登录态（同时尽量清理 WebView Cookie）。
  Future<void> clearSession() async {
    await saveCookieHeader('');
    for (final host in _cookieSourceHosts) {
      try {
        await CookieManager.instance().deleteCookies(url: WebUri(host));
      } catch (_) {
        continue;
      }
    }
  }

  // ---------------- 登录态校验 ----------------

  /// 本地 Cookie 是否包含 UID、_d、vc3 三个关键字段。
  Future<bool> hasRequiredAuthFields() async {
    final jar = _parseCookieHeader(await getCookieHeader());
    for (final key in _requiredCookieKeys) {
      final value = jar[key];
      if (value == null || value.isEmpty) return false;
    }
    return true;
  }

  /// 是否处于有效登录态。
  ///
  /// 1. 本地 Cookie 必须包含 UID / _d / vc3；
  /// 2. 用 Dio 访问一次个人空间，若被 302 重定向到 passport 登录页则视为失效。
  Future<bool> hasValidSession() async {
    final header = await getCookieHeader(forceReload: true);
    if (header.isEmpty) return false;

    final jar = _parseCookieHeader(header);
    for (final key in _requiredCookieKeys) {
      final value = jar[key];
      if (value == null || value.isEmpty) return false;
    }

    return _verifyWithServer(header);
  }

  /// 请求个人空间，判断是否被重定向到登录页。
  Future<bool> _verifyWithServer(String cookieHeader) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
        headers: <String, dynamic>{
          'Cookie': cookieHeader,
          'Referer': moocReferer,
          'User-Agent': desktopUserAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );

    try {
      final response = await dio.get<String>(
        _sessionProbeUrl,
        options: Options(responseType: ResponseType.plain),
      );

      final status = response.statusCode ?? 0;

      // 302 / 303 / 307：跟随 Location 判断是否被踢回登录页
      if (status >= 300 && status < 400) {
        final location = (response.headers.value('location') ?? '').toLowerCase();
        final redirectedToLogin =
            location.contains('passport') || location.contains('login');
        return !redirectedToLogin;
      }

      if (status != 200) return false;

      // 部分场景返回 200，但正文就是登录落地页
      final body = (response.data ?? '').toLowerCase();
      if (body.contains('passport2.chaoxing.com/login')) return false;
      if (body.contains('用户登录') && body.contains('passport')) return false;

      return true;
    } catch (_) {
      // 网络异常时不武断判定为已登录，交由上层引导重新登录
      return false;
    }
  }

  /// 解析 `k1=v1; k2=v2`，返回小写 key 的映射（Cookie 名大小写敏感但校验不敏感）。
  Map<String, String> _parseCookieHeader(String header) {
    final map = <String, String>{};
    if (header.isEmpty) return map;

    for (final part in header.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      final key = part.substring(0, index).trim().toLowerCase();
      final value = part.substring(index + 1).trim();
      if (key.isEmpty) continue;
      map[key] = value;
    }
    return map;
  }
}
