import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 单测里的加密存储替身：把 Keystore 换成一张内存 Map。
///
/// 返回的 Map 就是存储本体，测试可以直接断言「里面究竟写了什么」，
/// 从而验证 API Key 确实走的是加密存储、而不是明文 SharedPreferences。
Map<String, String> installSecureStorage([Map<String, String>? seed]) {
  final store = <String, String>{...?seed};
  FlutterSecureStorage.setMockInitialValues(store);
  return store;
}
