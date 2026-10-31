import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 超星（学习通）Cookie 同步与登录态校验。
///
/// 职责：
/// 1. 从 WebView 的 CookieManager 中聚合 .chaoxing.com 各子域 Cookie，去重拼接为
///    `k1=v1; k2=v2` 形式的请求头字符串；
/// 2. 持久化到 SharedPreferences，供 Dio 复用；
/// 3. **纯本地**校验登录态（只看 Cookie 字段是否齐全）。
///
/// 为什么启动时不再向服务器发一次「在不在线」的探查请求：
/// 本项目的红线是**任何对学习通的请求都必须由用户手动点击触发**。
/// 启动即联网会破坏这条边界（也会让冷启动依赖网络）。
/// 登录态真失效时，用户点刷新会收到「登录态已失效，请重新登录」，
/// 打开课程页也会被跳转到登录页——两条路径都能兜住，无需启动时预探。
class CookieSyncHelper {
  CookieSyncHelper._();

  static final CookieSyncHelper instance = CookieSyncHelper._();

  // ---------------- 常量 ----------------

  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const String moocReferer = 'https://mooc1.chaoxing.com/';

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

  /// 本地是否处于「看起来已登录」的状态。
  ///
  /// **纯本地判断，不发任何网络请求**：只检查 Cookie 里 UID / _d / vc3
  /// 三个关键字段是否齐全。
  ///
  /// 真实有效性交给两条用户主动触发的路径去发现：
  ///  - 点「刷新」时页面被踢回登录页 → 报「登录态已失效，请重新登录」；
  ///  - 打开课程/作业页时被跳转到登录页 → 走登录流程重新同步 Cookie。
  Future<bool> hasLocalSession() => hasRequiredAuthFields();

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
