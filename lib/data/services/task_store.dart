import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scanner_service.dart';

/// 手动提取到的作业列表本地缓存。
///
/// 因为不做后台自动抓取，杀掉进程后内存数据会丢，所以把 `List<HomeworkItem>`
/// 序列化成 JSON 存进 SharedPreferences，下次启动直接渲染。
class TaskStore {
  TaskStore._();

  static const String _prefsTasks = 'cfg_cached_tasks_v1';
  static const String _prefsView = 'cfg_dashboard_view';

  /// 读取缓存；解析失败时返回空列表并清理脏数据
  static Future<List<HomeworkItem>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsTasks);
    if (raw == null || raw.trim().isEmpty) return const <HomeworkItem>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <HomeworkItem>[];

      return decoded
          .whereType<Map>()
          .map((e) => HomeworkItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.url.trim().isNotEmpty && e.title.trim().isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[TaskStore] 缓存解析失败，已忽略: $e');
      await prefs.remove(_prefsTasks);
      return const <HomeworkItem>[];
    }
  }

  /// 覆盖写入（空列表等于清空）
  static Future<void> save(List<HomeworkItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    if (items.isEmpty) {
      await prefs.remove(_prefsTasks);
      return;
    }
    final json = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsTasks, json);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsTasks);
  }

  /// 记住上次的视图选择（byCourse / byTask）
  static Future<String?> loadView() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsView);
  }

  static Future<void> saveView(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsView, value);
  }
}
