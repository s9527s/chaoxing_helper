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

  /// 读取缓存；解析失败时返回空列表并清理脏数据。
  ///
  /// 缓存可能来自旧版本（当时还没做状态过滤，也没有稳定去重键），
  /// 所以这里在读出来时**再洗一遍**：丢掉已交/待批阅的、按稳定键去重。
  /// 洗过的结果和原来不一致时顺手回写，旧脏数据不会一直赖在缓存里。
  static Future<List<HomeworkItem>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsTasks);
    if (raw == null || raw.trim().isEmpty) return const <HomeworkItem>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <HomeworkItem>[];

      final parsed = decoded
          .whereType<Map>()
          .map((e) => HomeworkItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.url.trim().isNotEmpty && e.title.trim().isNotEmpty)
          .toList();

      final seen = <String>{};
      final cleaned = <HomeworkItem>[];
      for (final item in parsed) {
        if (!item.isPending) continue;
        if (!seen.add(item.stableKey)) continue;
        cleaned.add(item);
      }

      if (cleaned.length != parsed.length) {
        debugPrint(
          '[TaskStore] 缓存清洗：${parsed.length} → ${cleaned.length} 条'
          '（已交 ${parsed.length - cleaned.length} 条被淘汰）',
        );
        await save(cleaned);
      }

      return cleaned;
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

  // ---------------- 覆盖式合并（一次提取 → 一份新缓存） ----------------

  /// 把一次提取的结果合进缓存。**纯函数**，不碰磁盘，方便单测。
  ///
  /// 规则（网页是唯一事实来源）：
  ///  1. 提取结果先严格过滤：只要「未交 / 待交」，并按稳定键去重；
  ///  2. 提取结果涉及到的课程，缓存里这些课的旧数据**整批丢弃**，
  ///     不保留旧状态、不保留网页上已经没有的行；
  ///  3. 其他课程原样保留（这次没提取它们，不能连坐清空）；
  ///  4. 保留的旧数据也再洗一遍（已交的、重复的同样淘汰）。
  static ExtractionMerge mergeExtraction(
    List<HomeworkItem> cached,
    List<HomeworkItem> incoming,
  ) {
    final fresh = <HomeworkItem>[];
    final keys = <String>{};
    for (final item in incoming) {
      if (!item.isPending) continue;
      if (!keys.add(item.stableKey)) continue;
      fresh.add(item);
    }

    if (fresh.isEmpty) {
      // 这次什么都没提取到有效待办：缓存原样不动
      return ExtractionMerge(
        items: List<HomeworkItem>.unmodifiable(cached),
        added: 0,
        replaced: 0,
        dropped: 0,
      );
    }

    final scopeNames = <String>{
      for (final item in fresh)
        if (item.courseName.trim().isNotEmpty) item.courseName.trim(),
    };
    final scopeIds = <String>{
      for (final item in fresh) ...item.courseScopeKeys,
    };

    final next = <HomeworkItem>[];
    final nextKeys = <String>{};
    var replaced = 0;

    for (final old in cached) {
      final sameCourse = scopeNames.contains(old.courseName.trim()) ||
          old.courseScopeKeys.any(scopeIds.contains);
      if (sameCourse) {
        replaced++;
        continue;
      }
      if (!old.isPending) continue;
      if (!nextKeys.add(old.stableKey)) continue;
      next.add(old);
    }
    next.addAll(fresh);

    return ExtractionMerge(
      items: List<HomeworkItem>.unmodifiable(next),
      added: fresh.length,
      replaced: replaced,
      dropped: incoming.length - fresh.length,
    );
  }
}

/// 一次「提取 → 缓存」的结果统计，供 UI 提示
class ExtractionMerge {
  const ExtractionMerge({
    required this.items,
    required this.added,
    required this.replaced,
    required this.dropped,
  });

  /// 合并后的完整缓存（直接整表落盘）
  final List<HomeworkItem> items;

  /// 本次写入的有效待办条数
  final int added;

  /// 被覆盖掉的同课程旧数据条数
  final int replaced;

  /// 被过滤/去重掉的条数（已交、重复、无效行）
  final int dropped;
}
