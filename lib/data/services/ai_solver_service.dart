import 'dart:convert';
import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';

/// AI 解题服务：只发**一次** POST 到用户自己配置的模型接口。
///
/// 刻意只支持纯文字：
///  - 题干与选项都来自 `extractor.js` 的只读文本提取；
///  - **不下载任何页面资源**（图片/附件），因此这里不存在任何带 Cookie 的 GET；
///  - 除这一个 POST 之外，本类不发任何网络请求。
class AiSolverService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 90),
    ),
  );

  Future<List<Map<String, dynamic>>> solveQuestions({
    required List<Map<String, dynamic>> questions,
    /// 模型列表，按顺序依次尝试，前一个失败自动换下一个
    required List<LlmModel> models,
    void Function(String)? onLog,
  }) async {
    final List<Map<String, dynamic>> contentParts = [
      {
        'type': 'text',
        'text': '你是一个专业的大学课程解题助手。请根据提供的题目文本作答。\n'
            '请严格只输出 JSON 数组，不要包含 ```json 代码块或任何多余解释。\n'
            '输出格式示例：\n'
            '[{"index": 1, "type": "single", "answer": "B"}, '
            '{"index": 2, "type": "multiple", "answer": ["A", "C"]}]'
      }
    ];

    for (final q in questions) {
      if (q['skip'] == true) continue;
      final options = List<Map<String, dynamic>>.from(
        (q['options'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      final optionsSummary = options.map((o) => '${o['label']}: ${o['text']}').join(' | ');
      contentParts.add({
        'type': 'text',
        'text': '\n【第 ${q['index']} 题】题型: ${q['type']}\n题干: ${q['stem']}\n选项: $optionsSummary'
      });
    }

    // 只有填了 Key 的模型才真正可用
    final usable = models
        .where((m) => m.apiKey.trim().isNotEmpty && m.model.trim().isNotEmpty)
        .toList();

    if (usable.isEmpty) {
      throw Exception('未配置可用的模型，请在设置里添加模型并填写 API Key');
    }

    final skipped = models.length - usable.length;
    if (skipped > 0) {
      onLog?.call('⚠️ 有 $skipped 个模型未填 Key，已跳过');
    }

    Object? lastError;
    for (var i = 0; i < usable.length; i++) {
      final item = usable[i];
      final label = item.label;
      try {
        onLog?.call('🤖 [${i + 1}/${usable.length}] 请求 $label（${item.model}）');
        final result = await _requestAI(
          item.baseUrl,
          item.apiKey,
          item.model,
          contentParts,
        );
        if (i > 0) {
          onLog?.call('✅ $label 返回成功');
        }
        return result;
      } catch (e) {
        lastError = e;
        onLog?.call('⚠️ $label 请求失败：${_describe(e)}，尝试下一个...');
      }
    }

    throw Exception('全部模型请求失败：${_describe(lastError ?? '未知错误')}');
  }

  /// 让报错文案更可读（常见 401/404 提示配置问题）
  String _describe(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401 || code == 403) return 'Key 无效或无权限（HTTP $code）';
      if (code == 404) return '接口地址不存在（HTTP 404），请检查 BaseUrl';
      if (code == 429) return '请求太频繁或额度用尽（HTTP 429）';
      if (code != null) {
        final body = error.response?.data?.toString() ?? '';
        final brief = body.length > 120 ? body.substring(0, 120) : body;
        return 'HTTP $code $brief';
      }
      final message = error.message ?? '网络异常';
      // Android 9+ 起明文 HTTP 被系统直接拦掉，这里翻译成人话
      if (message.toUpperCase().contains('CLEARTEXT')) {
        return '地址必须是 https://（本应用禁止明文 HTTP）';
      }
      return message;
    }
    return error.toString();
  }

  Future<List<Map<String, dynamic>>> _requestAI(String apiUrl, String apiKey, String model, List<Map<String, dynamic>> parts) async {
    final response = await _dio.post(
      apiUrl,
      options: Options(headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'}),
      data: {'model': model, 'messages': [{'role': 'user', 'content': parts}], 'temperature': 0.1},
    );
    final choices = response.data['choices'] as List?;
    if (choices == null || choices.isEmpty) throw Exception('AI 返回结果为空');
    String rawContent = choices[0]['message']['content'].toString().trim();
    rawContent = rawContent.replaceAll(RegExp(r'^```json\s*|\s*```$'), '').trim();
    final startIdx = rawContent.indexOf('[');
    final endIdx = rawContent.lastIndexOf(']');
    if (startIdx != -1 && endIdx != -1) rawContent = rawContent.substring(startIdx, endIdx + 1);
    final decoded = jsonDecode(rawContent) as List;
    return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
}
