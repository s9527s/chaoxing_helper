import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个大模型配置项（OpenAI 兼容）。
class LlmModel {
  const LlmModel({
    this.id = '',
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  /// 稳定标识：API Key 按它在加密存储里占一个槽位（`cfg_api_key_<id>`）。
  /// 老配置没有这个字段，首次读取时由 [AppConfig] 补齐并写回。
  final String id;

  /// 展示名，例如「DeepSeek」「Kimi」
  final String name;

  /// 接口地址（完整 chat/completions）
  final String baseUrl;

  /// 模型名，例如 deepseek-chat
  final String model;

  /// API Key（只存在于内存与系统加密存储，不写进 SharedPreferences）
  final String apiKey;

  bool get hasKey => apiKey.trim().isNotEmpty;

  /// 四个字段全空 → 视为未填写的占位卡，保存时丢弃
  bool get isBlank =>
      name.trim().isEmpty &&
      baseUrl.trim().isEmpty &&
      model.trim().isEmpty &&
      apiKey.trim().isEmpty;

  /// 能真正拿去发请求
  bool get isUsable =>
      hasKey && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// 日志/UI 上显示的名字
  String get label => name.trim().isEmpty ? model.trim() : name.trim();

  LlmModel copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) {
    return LlmModel(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  /// 规范化：地址补全、字段 trim、名称/模型兜底（id 原样保留）
  LlmModel normalized() {
    final normalizedModel = AppConfig.normalizeModel(
      model,
      fallback: AppConfig.defaultDeepseekModel,
    );
    final normalizedName = name.trim().isEmpty ? normalizedModel : name.trim();
    return LlmModel(
      id: id,
      name: normalizedName,
      baseUrl: AppConfig.normalizeEndpoint(
        baseUrl,
        fallback: AppConfig.defaultDeepseekBaseUrl,
      ),
      model: normalizedModel,
      apiKey: apiKey.trim(),
    );
  }

  /// 写进 SharedPreferences 的**元数据**：刻意不含 [apiKey]
  Map<String, dynamic> toMetaJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
      };

  /// 兼容读取：旧版 JSON 里带 `apiKey` 明文，这里仍能读出来，
  /// 由 [AppConfig.init] 负责迁进加密存储。
  factory LlmModel.fromJson(Map<String, dynamic> json) {
    return LlmModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      apiKey: (json['apiKey'] ?? '').toString(),
    );
  }

  @override
  String toString() => 'LlmModel($name, $model, ${AppConfig.maskKey(apiKey)})';
}

/// 全局运行配置：模型列表（含 Key / 接口地址 / 模型名）。
///
/// 存储分工（刻意拆开，做到「最小化敏感数据落盘」）：
///  - **API Key** → 系统加密存储（Android 为 EncryptedSharedPreferences，
///    密钥由 Keystore 派生），一把 Key 一个槽位：`cfg_api_key_<id>`；
///  - **模型元数据**（名称 / 地址 / 模型名）→ SharedPreferences 明文 JSON，不含 Key。
///
/// 旧版本把整份列表（含 Key 明文）写在一个 JSON 里，[init] 会把其中的 Key 迁进
/// 加密存储，**确认写成功后才**改写明文 JSON；失败则原样保留，下次启动重试。
class AppConfig {
  AppConfig._();

  // ---------------- 存储 key ----------------

  /// 模型元数据（JSON 数组，不含 Key）
  static const String _prefsLlmModels = 'cfg_llm_models';

  /// 旧版固定单模型配置（仅用于升级迁移）
  static const String _legacyPrefsDeepseekKey = 'cfg_deepseek_key';
  static const String _legacyPrefsQwenKey = 'cfg_qwen_key';
  static const String _legacyPrefsDeepseekBaseUrl = 'cfg_deepseek_base_url';
  static const String _legacyPrefsDeepseekModel = 'cfg_deepseek_model';
  static const String _legacyPrefsQwenBaseUrl = 'cfg_qwen_base_url';
  static const String _legacyPrefsQwenModel = 'cfg_qwen_model';

  /// 加密存储：Android 走 EncryptedSharedPreferences（API 23+，本项目 minSdk 24）
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 一把 Key 一个槽位，避免多模型互相覆盖
  static String _keySlot(String modelId) => 'cfg_api_key_$modelId';

  // ---------------- 默认值 ----------------

  static const String defaultDeepseekBaseUrl =
      'https://api.deepseek.com/v1/chat/completions';
  static const String defaultDeepseekModel = 'deepseek-chat';
  static const String defaultQwenBaseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
  static const String defaultQwenModel = 'qwen-vl-max';

  static const String defaultWorkUrl = 'https://mooc1.chaoxing.com/';

  /// 首次启动的预设（Key 留空，等用户填）
  static const List<LlmModel> defaultLlmModels = <LlmModel>[
    LlmModel(
      name: 'DeepSeek',
      baseUrl: defaultDeepseekBaseUrl,
      model: defaultDeepseekModel,
      apiKey: '',
    ),
    LlmModel(
      name: '通义千问',
      baseUrl: defaultQwenBaseUrl,
      model: defaultQwenModel,
      apiKey: '',
    ),
  ];

  // ---------------- 运行时值（内存） ----------------

  static List<LlmModel> _llmModels = List<LlmModel>.of(defaultLlmModels);

  /// 当前模型列表（副本，避免外部直接改内存）
  static List<LlmModel> getLlmModels() => List<LlmModel>.unmodifiable(_llmModels);

  /// 填写了 Key、可以真正发请求的模型
  static List<LlmModel> get usableLlmModels =>
      _llmModels.where((m) => m.isUsable).toList();

  static bool get hasUsableModel => usableLlmModels.isNotEmpty;

  // ---------------- 规范化 ----------------

  /// 规范化 OpenAI 兼容地址：
  /// * 空 → 回落默认值；
  /// * 只填了 base（如 `https://api.moonshot.cn/v1`）→ 自动补 `/chat/completions`；
  /// * 已带 `/chat/completions` → 原样保留；
  /// * 没写协议 → 补 `https://`；
  /// * 顺手去掉粘贴时带上的引号与尾部斜杠。
  static String normalizeEndpoint(String raw, {required String fallback}) {
    var url = raw.trim();
    if (url.isEmpty) return fallback;

    if ((url.startsWith('"') && url.endsWith('"')) ||
        (url.startsWith("'") && url.endsWith("'"))) {
      url = url.substring(1, url.length - 1).trim();
    }
    if (url.isEmpty) return fallback;

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.contains('/chat/completions')) {
      url = '$url/chat/completions';
    }
    return url;
  }

  /// 模型名留空 → 回落默认值
  static String normalizeModel(String raw, {required String fallback}) {
    final model = raw.trim();
    return model.isEmpty ? fallback : model;
  }

  static String maskKey(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return '未配置';
    if (trimmed.length <= 8) return '已配置';
    return '${trimmed.substring(0, 4)}***${trimmed.substring(trimmed.length - 4)}';
  }

  // ---------------- 读写 ----------------

  /// App 启动初始化，runApp 之前 await
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    var models =
        _readMeta(prefs) ??
        _modelsFromLegacySingleKeys(prefs) ??
        List<LlmModel>.of(defaultLlmModels);

    // Key 按 id 存放，id 必须跨重启不变
    models = _assignIds(models);
    _llmModels = models;

    // 旧版明文 Key → 加密存储。全部写成功才允许改写 SharedPreferences
    if (_llmModels.any((m) => m.apiKey.trim().isNotEmpty)) {
      final migrated = await _migratePlainKeysToSecure(_llmModels);
      if (!migrated) {
        // 写失败：明文保持原样（下次启动还能再迁），这次直接用内存里的 Key
        debugPrint('[AppConfig] API Key 迁移失败，已保留旧配置，下次启动重试');
        return;
      }
    }

    // 只写元数据（不含 Key），并清掉更老的单模型明文字段
    await _persistMeta(prefs);
    await _clearLegacySingleKeyFields(prefs);

    // 内存里还没有的 Key，从加密存储读回来
    await _hydrateKeysFromSecure();
  }

  static Future<void> load() => init(); // 兼容旧调用名

  /// 读元数据 JSON（旧版可能带 `apiKey` 明文，仍能读出来交给迁移流程）
  static List<LlmModel>? _readMeta(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsLlmModels);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final models = decoded
          .whereType<Map>()
          .map((e) => LlmModel.fromJson(Map<String, dynamic>.from(e)).normalized())
          .toList();
      return models.isEmpty ? null : models;
    } catch (e) {
      debugPrint('[AppConfig] 模型配置解析失败: $e');
      return null;
    }
  }

  /// 最早的固定单模型配置（DeepSeek + 千问）。没有任何旧值时返回 null。
  static List<LlmModel>? _modelsFromLegacySingleKeys(SharedPreferences prefs) {
    final deepseekKey = prefs.getString(_legacyPrefsDeepseekKey) ?? '';
    final qwenKey = prefs.getString(_legacyPrefsQwenKey) ?? '';
    if (deepseekKey.isEmpty && qwenKey.isEmpty) return null;

    final deepseekBaseUrl = prefs.getString(_legacyPrefsDeepseekBaseUrl) ?? '';
    final deepseekModel = prefs.getString(_legacyPrefsDeepseekModel) ?? '';
    final qwenBaseUrl = prefs.getString(_legacyPrefsQwenBaseUrl) ?? '';
    final qwenModel = prefs.getString(_legacyPrefsQwenModel) ?? '';

    return <LlmModel>[
      LlmModel(
        name: 'DeepSeek',
        baseUrl: normalizeEndpoint(deepseekBaseUrl, fallback: defaultDeepseekBaseUrl),
        model: normalizeModel(deepseekModel, fallback: defaultDeepseekModel),
        apiKey: deepseekKey.trim(),
      ),
      LlmModel(
        name: '通义千问',
        baseUrl: normalizeEndpoint(qwenBaseUrl, fallback: defaultQwenBaseUrl),
        model: normalizeModel(qwenModel, fallback: defaultQwenModel),
        apiKey: qwenKey.trim(),
      ),
    ];
  }

  /// 给没有 id 的模型补一个稳定 id（同一进程内不重复）
  static List<LlmModel> _assignIds(List<LlmModel> models) {
    final used = models.map((m) => m.id).where((id) => id.isNotEmpty).toSet();
    var seq = 0;
    return models.map((m) {
      if (m.id.isNotEmpty) return m;
      String id;
      do {
        id = 'm${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
            '${seq++}';
      } while (used.contains(id));
      used.add(id);
      return m.copyWith(id: id);
    }).toList();
  }

  /// 把旧版明文 Key 逐把写进加密存储，**每把都读回核对**。
  ///
  /// 任何一把失败就返回 false，调用方据此**不改动 SharedPreferences**——
  /// 宁可这次不迁移，也不能出现「Key 删了但没存进加密存储」。
  static Future<bool> _migratePlainKeysToSecure(List<LlmModel> models) async {
    for (final model in models) {
      final key = model.apiKey.trim();
      if (key.isEmpty) continue;
      if (!await _writeKeyVerified(model.id, key)) return false;
    }
    return true;
  }

  /// 写一把 Key 并读回核对；成功才返回 true
  static Future<bool> _writeKeyVerified(String modelId, String apiKey) async {
    final slot = _keySlot(modelId);
    try {
      await _secure.write(key: slot, value: apiKey);
      final back = await _secure.read(key: slot);
      if (back == apiKey) return true;
      debugPrint('[AppConfig] 加密存储读回不一致，视为写入失败');
      return false;
    } catch (e) {
      debugPrint('[AppConfig] 写入加密存储失败: $e');
      return false;
    }
  }

  /// 从加密存储补全内存里缺失的 Key
  static Future<void> _hydrateKeysFromSecure() async {
    for (var i = 0; i < _llmModels.length; i++) {
      final model = _llmModels[i];
      if (model.apiKey.isNotEmpty) continue;
      try {
        final key = await _secure.read(key: _keySlot(model.id));
        if (key != null && key.isNotEmpty) {
          _llmModels[i] = model.copyWith(apiKey: key);
        }
      } catch (e) {
        debugPrint('[AppConfig] 读取加密 Key 失败: $e');
      }
    }
  }

  /// 只写元数据（不含任何 Key）
  static Future<void> _persistMeta(SharedPreferences prefs) async {
    if (_llmModels.isEmpty) {
      await prefs.remove(_prefsLlmModels);
      return;
    }
    final json = jsonEncode(_llmModels.map((m) => m.toMetaJson()).toList());
    await prefs.setString(_prefsLlmModels, json);
  }

  /// 老版本的单模型明文字段：迁移完成后删掉
  static Future<void> _clearLegacySingleKeyFields(SharedPreferences prefs) async {
    for (final key in <String>[
      _legacyPrefsDeepseekKey,
      _legacyPrefsQwenKey,
      _legacyPrefsDeepseekBaseUrl,
      _legacyPrefsDeepseekModel,
      _legacyPrefsQwenBaseUrl,
      _legacyPrefsQwenModel,
    ]) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    }
  }

  /// 保存模型列表。
  ///
  /// 顺序是刻意的：**先写 Key 到加密存储并读回核对**，全部成功后
  /// 才更新内存与 SharedPreferences 元数据。返回 false 表示有 Key 没存进去，
  /// 此时不改任何持久化数据，界面应提示重试。
  static Future<bool> saveLlmModels(List<LlmModel> models) async {
    final cleaned = _assignIds(
      models.where((m) => !m.isBlank).map((m) => m.normalized()).toList(),
    );

    // 1) Key → 加密存储
    for (final model in cleaned) {
      final key = model.apiKey.trim();
      if (key.isEmpty) {
        try {
          await _secure.delete(key: _keySlot(model.id));
        } catch (e) {
          debugPrint('[AppConfig] 删除旧 Key 失败: $e');
        }
        continue;
      }
      if (!await _writeKeyVerified(model.id, key)) return false;
    }

    // 2) 已被删掉的模型：顺手清掉它留在加密存储里的槽位
    final alive = cleaned.map((m) => m.id).toSet();
    for (final old in _llmModels) {
      if (old.id.isEmpty || alive.contains(old.id)) continue;
      try {
        await _secure.delete(key: _keySlot(old.id));
      } catch (e) {
        debugPrint('[AppConfig] 清理废弃 Key 失败: $e');
      }
    }

    // 3) 元数据 → SharedPreferences（不含 Key）
    _llmModels = cleaned;
    final prefs = await SharedPreferences.getInstance();
    await _persistMeta(prefs);
    return true;
  }

  /// 清空全部模型配置
  static Future<void> clearModels() async {
    await saveLlmModels(const <LlmModel>[]);
  }

  /// 恢复默认预设（Key 为空）
  static Future<void> resetToDefaults() async {
    await saveLlmModels(List<LlmModel>.of(defaultLlmModels));
  }
}
