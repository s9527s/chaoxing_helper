import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scanner_service.dart';

/// 课程快捷入口的本地缓存。
///
/// 学习通没有「全部课程待办聚合页」，所以作业只能一门课一门课地进。
/// 这里把用户进过的课程地址存下来，在主页渲染成快捷卡片，
/// 点一下就直接跳到该课程的作业列表，省掉在网页里翻找课程的步骤。
///
/// 数据来源有两条（都不涉及点击或自动遍历）：
///  1. 在课程列表页点「保存全部课程」→ 只读 DOM 解析整页课程卡片；
///  2. 手动进到某门课点「提取本页作业」→ 顺带记下当前页面地址（带 enc）。
class CourseStore {
  CourseStore._();

  static const String _prefsCourses = 'cfg_courses_v1';

  /// 读取缓存；解析失败时返回空列表并清理脏数据
  static Future<List<CourseRef>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsCourses);
    if (raw == null || raw.trim().isEmpty) return const <CourseRef>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <CourseRef>[];

      return decoded
          .whereType<Map>()
          .map((e) => CourseRef.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.hasIds && e.courseName.trim().isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[CourseStore] 缓存解析失败，已忽略: $e');
      await prefs.remove(_prefsCourses);
      return const <CourseRef>[];
    }
  }

  /// 覆盖写入（空列表等于清空）
  static Future<void> save(List<CourseRef> courses) async {
    final prefs = await SharedPreferences.getInstance();
    if (courses.isEmpty) {
      await prefs.remove(_prefsCourses);
      return;
    }
    final json = jsonEncode(courses.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsCourses, json);
  }

  /// 合并一批课程：已有则补全信息，没有则追加。
  /// 返回新增的门数。
  static Future<int> upsertMany(List<CourseRef> incoming) async {
    if (incoming.isEmpty) return 0;

    final stored = List<CourseRef>.of(await load());
    final index = <String, int>{
      for (var i = 0; i < stored.length; i++) stored[i].key: i,
    };

    var added = 0;
    for (final course in incoming) {
      if (!course.hasIds) continue;

      final position = index[course.key];
      if (position == null) {
        // 连名字都没有就不建卡片（避免长出「课程 123456」这种没法认的入口）
        if (course.courseName.trim().isEmpty) continue;
        index[course.key] = stored.length;
        stored.add(course);
        added++;
      } else {
        // 已有这门课：只做信息补全（尤其是补 enc 和作业列表地址）
        stored[position] = stored[position].mergeWith(course);
      }
    }

    await save(stored);
    return added;
  }

  /// 合并单门课程
  static Future<int> upsert(CourseRef course) => upsertMany(<CourseRef>[course]);

  static Future<void> remove(String key) async {
    final stored = (await load()).where((e) => e.key != key).toList();
    await save(stored);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsCourses);
  }
}
