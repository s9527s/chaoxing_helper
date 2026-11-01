import 'dart:convert';

import 'package:ai_web_reader/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> secureStore;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secureStore = installSecureStorage();
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

    // 预设也要有稳定 id，之后才有地方挂 Key
    expect(models[0].id, isNotEmpty);
    expect(models[0].id, isNot(models[1].id));
  });

  test('保存列表：地址规范化、空项丢弃、Key 进加密存储', () async {
    await AppConfig.init();

    final ok = await AppConfig.saveLlmModels(<LlmModel>[
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
    expect(ok, isTrue);

    final saved = AppConfig.getLlmModels();
    expect(saved, hasLength(2), reason: '全空占位项应被丢弃');
    expect(saved[0].baseUrl, 'https://api.moonshot.cn/v1/chat/completions');
    expect(saved[0].model, 'moonshot-v1-8k', reason: '应 trim');
    expect(saved[0].apiKey, 'sk-kimi-123456');
    expect(saved[1].baseUrl, 'https://relay.example.com/v1/chat/completions',
        reason: '缺协议时补 https');
    expect(saved[1].name, 'gpt-4o-mini', reason: '名称留空时回落模型名');

    expect(AppConfig.usableLlmModels, hasLength(2));
    expect(AppConfig.hasUsableModel, isTrue);

    // Key 只在加密存储里，一把一个槽位
    expect(secureStore['cfg_api_key_${saved[0].id}'], 'sk-kimi-123456');
    expect(secureStore['cfg_api_key_${saved[1].id}'], 'sk-relay-abcdef');

    // SharedPreferences 只放元数据，**不允许出现任何 Key**
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cfg_llm_models');
    expect(raw, isNotNull);
    expect(raw, contains('Kimi'), reason: '元数据仍留在明文配置里');
    expect(raw, isNot(contains('sk-')), reason: '明文配置里不能有 Key');
    expect(raw, isNot(contains('apiKey')));

    // 模拟重启：Key 从加密存储读回
    await AppConfig.init();
    final reloaded = AppConfig.getLlmModels();
    expect(reloaded, hasLength(2));
    expect(reloaded[0].name, 'Kimi');
    expect(reloaded[0].apiKey, 'sk-kimi-123456');
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

  test('旧版固定 DeepSeek/千问 配置：Key 迁进加密存储，明文字段删除', () async {
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

    // Key 已在加密存储里
    expect(secureStore.values, contains('sk-old-deepseek'));
    expect(secureStore.values, contains('sk-old-qwen'));

    // 明文旧字段被清掉
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cfg_deepseek_key'), isNull);
    expect(prefs.getString('cfg_qwen_key'), isNull);
  });

  test('旧版明文 JSON 里的 Key 迁进加密存储，明文副本被清掉', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cfg_llm_models': jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Kimi',
          'baseUrl': 'https://api.moonshot.cn/v1',
          'model': 'moonshot-v1-8k',
          'apiKey': 'sk-legacy-kimi',
        },
      ]),
    });

    await AppConfig.init();

    expect(AppConfig.getLlmModels().single.apiKey, 'sk-legacy-kimi');
    expect(AppConfig.usableLlmModels, hasLength(1));

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cfg_llm_models');
    expect(raw, isNotNull);
    expect(raw, isNot(contains('sk-legacy-kimi')), reason: '明文里不该再有 Key');
    expect(raw, contains('Kimi'), reason: '普通模型配置仍留在 SharedPreferences');

    expect(secureStore.values, contains('sk-legacy-kimi'));

    // 再启动一次：Key 从加密存储读回，不再依赖明文
    await AppConfig.init();
    expect(AppConfig.getLlmModels().single.apiKey, 'sk-legacy-kimi');
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
