import 'package:ai_web_reader/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('首次启动给出 DeepSeek / 千问 预设（Key 为空）', () async {
    await AppConfig.init();

    final models = AppConfig.getLlmModels();
    expect(models, hasLength(2));
    expect(models[0].name, 'DeepSeek');
    expect(models[0].model, 'deepseek-chat');
    expect(models[0].baseUrl, AppConfig.defaultDeepseekBaseUrl);
    expect(models[0].apiKey, isEmpty);
    expect(models[1].name, '通义千问');
    expect(models[1].model, 'qwen-vl-max');
    expect(models[1].apiKey, isEmpty);

    // 没填 Key 一个都用不了
    expect(AppConfig.hasUsableModel, isFalse);
    expect(AppConfig.usableLlmModels, isEmpty);
  });

  test('保存列表：规范化地址与字段、丢弃全空项、可重新读回', () async {
    await AppConfig.init();

    await AppConfig.saveLlmModels(<LlmModel>[
      const LlmModel(
        name: 'Kimi',
        baseUrl: 'https://api.moonshot.cn/v1/',
        model: ' moonshot-v1-8k ',
        apiKey: ' sk-kimi-123456 ',
      ),
      const LlmModel(name: '', baseUrl: '', model: '', apiKey: ''), // 全空 → 丢弃
      const LlmModel(
        name: '',
        baseUrl: 'relay.example.com/v1',
        model: 'gpt-4o-mini',
        apiKey: 'sk-relay-abcdef',
      ),
    ]);

    final saved = AppConfig.getLlmModels();
    expect(saved, hasLength(2), reason: '全空占位项应被丢弃');
    expect(saved[0].baseUrl, 'https://api.moonshot.cn/v1/chat/completions');
    expect(saved[0].model, 'moonshot-v1-8k', reason: '应 trim');
    expect(saved[0].apiKey, 'sk-kimi-123456');
    expect(saved[1].baseUrl, 'https://relay.example.com/v1/chat/completions',
        reason: '缺协议时补 https');
    expect(saved[1].name, 'gpt-4o-mini', reason: '名称留空时回落模型名');

    // 可用模型 = 填了 Key 的
    expect(AppConfig.usableLlmModels, hasLength(2));
    expect(AppConfig.hasUsableModel, isTrue);

    // 模拟重启：从本地 JSON 读回
    await AppConfig.init();
    final reloaded = AppConfig.getLlmModels();
    expect(reloaded, hasLength(2));
    expect(reloaded[0].name, 'Kimi');
    expect(reloaded[0].apiKey, 'sk-kimi-123456');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cfg_llm_models');
    expect(raw, isNotNull);
    expect(raw, contains('Kimi'));
  });

  test('没有 Key 的模型不算可用，但仍会保存在列表里', () async {
    await AppConfig.init();
    await AppConfig.saveLlmModels(<LlmModel>[
      const LlmModel(
        name: 'DeepSeek',
        baseUrl: AppConfig.defaultDeepseekBaseUrl,
        model: 'deepseek-chat',
        apiKey: '',
      ),
      const LlmModel(
        name: '千问',
        baseUrl: AppConfig.defaultQwenBaseUrl,
        model: 'qwen-vl-max',
        apiKey: 'sk-qwen-key',
      ),
    ]);

    expect(AppConfig.getLlmModels(), hasLength(2));
    expect(AppConfig.usableLlmModels, hasLength(1));
    expect(AppConfig.usableLlmModels.single.name, '千问');
  });

  test('旧版固定 DeepSeek/千问 配置可迁移到模型列表', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cfg_deepseek_key': 'sk-old-deepseek',
      'cfg_qwen_key': 'sk-old-qwen',
      'cfg_deepseek_model': 'deepseek-chat',
      'cfg_qwen_model': 'qwen-vl-max',
    });

    await AppConfig.init();
    final models = AppConfig.getLlmModels();
    expect(models, hasLength(2));
    expect(models[0].name, 'DeepSeek');
    expect(models[0].apiKey, 'sk-old-deepseek');
    expect(models[1].apiKey, 'sk-old-qwen');
    expect(AppConfig.usableLlmModels, hasLength(2));

    // 迁移后应写入新的 JSON key，避免下次重复迁移
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cfg_llm_models'), isNotNull);
  });

  test('normalizeEndpoint：不重复拼接、去引号、空值回落', () {
    expect(
      AppConfig.normalizeEndpoint(
        'https://api.deepseek.com/v1/chat/completions',
        fallback: AppConfig.defaultDeepseekBaseUrl,
      ),
      'https://api.deepseek.com/v1/chat/completions',
    );
    expect(
      AppConfig.normalizeEndpoint(
        '"https://relay.example.com/v1/chat/completions"',
        fallback: AppConfig.defaultDeepseekBaseUrl,
      ),
      'https://relay.example.com/v1/chat/completions',
      reason: '去掉粘贴时带上的引号',
    );
    expect(
      AppConfig.normalizeEndpoint('', fallback: AppConfig.defaultQwenBaseUrl),
      AppConfig.defaultQwenBaseUrl,
    );
  });

  test('maskKey 脱敏', () {
    expect(AppConfig.maskKey(''), '未配置');
    expect(AppConfig.maskKey('short'), '已配置');
    expect(AppConfig.maskKey('sk-1234567890'), 'sk-1***7890');
  });
}
