import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个大模型配置项（OpenAI 兼容）。
class LlmModel {
  const LlmModel({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  /// 展示名，例如「DeepSeek」「Kimi」
  final String name;

  /// 接口地址（完整 chat/completions）
  final String baseUrl;

  /// 模型名，例如 deepseek-chat
  final String model;

  /// API Key
  final String apiKey;

  bool get hasKey => apiKey.trim().isNotEmpty;

  /// 四个字段全空 → 视为未填写的占位卡，保存时丢弃
  bool get isBlank =>
      name.trim().isEmpty &&
      baseUrl.trim().isEmpty &&
      model.trim().isEmpty &&
      apiKey.trim().isEmpty;

  /// 能真正拿去发请求
  bool get isUsable => hasKey && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// 日志/UI 上显示的名字
  String get label => name.trim().isEmpty ? model.trim() : name.trim();

  LlmModel copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) {
    return LlmModel(
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  /// 规范化：地址补全、字段 trim、名称/模型兜底
  LlmModel normalized() {
    final normalizedModel = AppConfig.normalizeModel(
      model,
      fallback: AppConfig.defaultDeepseekModel,
    );
    final normalizedName = name.trim().isEmpty ? normalizedModel : name.trim();
    return LlmModel(
      name: normalizedName,
      baseUrl: AppConfig.normalizeEndpoint(
        baseUrl,
        fallback: AppConfig.defaultDeepseekBaseUrl,
      ),
      model: normalizedModel,
      apiKey: apiKey.trim(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'apiKey': apiKey,
      };

  factory LlmModel.fromJson(Map<String, dynamic> json) {
    return LlmModel(
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      apiKey: (json['apiKey'] ?? '').toString(),
    );
  }

  @override
  String toString() => 'LlmModel($name, $model, ${AppConfig.maskKey(apiKey)})';
}

/// 全局运行配置：模型列表（含 Key / 接口地址 / 模型名），持久化在 SharedPreferences。
///
/// 模型列表按 **OpenAI 兼容格式** 配置，可自由增删：
/// DeepSeek、通义千问、Kimi、豆包、任意第三方中转站都行。
/// 请求时按列表顺序依次尝试，前一个失败自动换下一个。
class AppConfig {
  AppConfig._();

  // ---------------- prefs key ----------------

  /// 模型列表（JSON 字符串）
  static const String _prefsLlmModels = 'cfg_llm_models';

  // 旧版单模型配置（仅用于升级迁移）
  static const String _legacyPrefsDeepseekKey = 'cfg_deepseek_key';
  static const String _legacyPrefsQwenKey = 'cfg_qwen_key';
  static const String _legacyPrefsDeepseekBaseUrl = 'cfg_deepseek_base_url';
  static const String _legacyPrefsDeepseekModel = 'cfg_deepseek_model';
  static const String _legacyPrefsQwenBaseUrl = 'cfg_qwen_base_url';
  static const String _legacyPrefsQwenModel = 'cfg_qwen_model';

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
    final raw = prefs.getString(_prefsLlmModels);

    if (raw == null || raw.trim().isEmpty) {
      // 首次启动：尝试从旧版单模型配置迁移，失败则用预设
      final migrated = _migrateLegacy(prefs);
      if (migrated != null) {
        _llmModels = migrated;
        await _persist(prefs);
      } else {
        _llmModels = List<LlmModel>.of(defaultLlmModels);
      }
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _llmModels = decoded
            .whereType<Map>()
            .map((e) => LlmModel.fromJson(Map<String, dynamic>.from(e)).normalized())
            .toList();
        return;
      }
    } catch (e) {
      debugPrint('[AppConfig] 模型列表解析失败，使用预设: $e');
    }
    _llmModels = List<LlmModel>.of(defaultLlmModels);
  }

  static Future<void> load() => init(); // 兼容旧调用名

  /// 旧版（固定 DeepSeek + 千问）配置迁移。没有任何旧值时返回 null。
  static List<LlmModel>? _migrateLegacy(SharedPreferences prefs) {
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

  /// 保存模型列表：规范化 → 丢弃全空占位项 → 写 JSON
  static Future<void> saveLlmModels(List<LlmModel> models) async {
    final cleaned = models
        .where((m) => !m.isBlank)
        .map((m) => m.normalized())
        .toList();
    _llmModels = cleaned;

    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
  }

  static Future<void> _persist(SharedPreferences prefs) async {
    if (_llmModels.isEmpty) {
      await prefs.remove(_prefsLlmModels);
      return;
    }
    final json = jsonEncode(_llmModels.map((m) => m.toJson()).toList());
    await prefs.setString(_prefsLlmModels, json);
  }

  /// 清空全部模型配置
  static Future<void> clearModels() => saveLlmModels(const <LlmModel>[]);

  /// 恢复默认预设（Key 为空）
  static Future<void> resetToDefaults() async {
    _llmModels = List<LlmModel>.of(defaultLlmModels);
    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
  }
}
