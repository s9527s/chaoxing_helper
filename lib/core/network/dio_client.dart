import 'package:dio/dio.dart';

import 'cookie_sync_helper.dart';

/// 全局单例 Dio：自动携带超星登录 Cookie、Referer 与桌面版 UA。
///
/// 使用方式：
/// ```dart
/// final res = await DioClient.instance.dio.get('https://mooc1.chaoxing.com/...');
/// ```
class DioClient {
  DioClient._() {
    _dio = _buildDio();
  }

  static final DioClient instance = DioClient._();

  late final Dio _dio;

  Dio get dio => _dio;

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 30);

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
        followRedirects: true,
        headers: <String, dynamic>{
          'Referer': CookieSyncHelper.moocReferer,
          'User-Agent': CookieSyncHelper.desktopUserAgent,
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final cookie = await CookieSyncHelper.instance.getCookieHeader();
          if (cookie.isNotEmpty) {
            options.headers['Cookie'] = cookie;
          }
          options.headers.putIfAbsent(
            'Referer',
            () => CookieSyncHelper.moocReferer,
          );
          options.headers.putIfAbsent(
            'User-Agent',
            () => CookieSyncHelper.desktopUserAgent,
          );
          handler.next(options);
        },
        onError: (error, handler) {
          handler.next(error);
        },
      ),
    );

    return dio;
  }

  /// 登录态失效时清理本地 Cookie（例如收到 302 跳登录页）。
  Future<void> invalidateSession() => CookieSyncHelper.instance.clearSession();
}
