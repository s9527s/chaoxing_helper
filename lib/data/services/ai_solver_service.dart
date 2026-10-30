import 'dart:convert';
import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';

class AiSolverService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 90),
    ),
  );

  Future<String?> _downloadImageAsBase64({
    required String imageUrl,
    required String cookieHeader,
    required String userAgent,
    void Function(String)? onLog,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        imageUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Cookie': cookieHeader,
            'Referer': 'https://mooc1.chaoxing.com/',
            'User-Agent': userAgent,
          },
        ),
      );
      final bytes = response.data;
      if (response.statusCode == 200 && bytes != null && bytes.isNotEmpty) {
        final base64Str = base64Encode(bytes);
        final lowerUrl = imageUrl.toLowerCase();
        final mimeType = (lowerUrl.contains('.jpg') || lowerUrl.contains('.jpeg')) ? 'image/jpeg' : 'image/png';
        return 'data:$mimeType;base64,$base64Str';
      }
    } catch (e) {
      onLog?.call('⚠️ 图片下载失败，已跳过: $imageUrl ($e)');
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> solveQuestions({
    required List<Map<String, dynamic>> questions,
    /// 模型列表，按顺序依次尝试，前一个失败自动换下一个
    required List<LlmModel> models,
    required String cookieHeader,
    required String userAgent,
    void Function(String)? onLog,
    void Function(int current, int total)? onImageProgress,
  }) async {
    int totalImages = 0;
    for (final q in questions) {
      if (q['skip'] == true) continue;
      totalImages += ((q['stemImages'] as List?) ?? []).length;
      for (final opt in (q['options'] as List? ?? [])) {
        totalImages += ((opt['images'] as List?) ?? []).length;
      }
    }

    int processedImages = 0;
    final List<Map<String, dynamic>> contentParts = [
      {
        'type': 'text',
        'text': '你是一个专业的大学课程解题助手。请根据提供的题目文本和配图作答。\n'
            '请严格只输出 JSON 数组，不要包含 ```json 代码块或任何多余解释。\n'
            '输出格式示例：\n'
            '[{"index": 1, "type": "single", "answer": "B"}, '
            '{"index": 2, "type": "multiple", "answer": ["A", "C"]}]'
      }
    ];

    for (final q in questions) {
      if (q['skip'] == true) continue;
      final List<String> currentQuestionBase64List = [];
      final stemImgs = List<String>.from(q['stemImages'] ?? []);
      for (final url in stemImgs) {
        final b64 = await _downloadImageAsBase64(imageUrl: url, cookieHeader: cookieHeader, userAgent: userAgent, onLog: onLog);
        processedImages++;
        onImageProgress?.call(processedImages, totalImages);
        if (b64 != null) currentQuestionBase64List.add(b64);
      }
      final options = List<Map<String, dynamic>>.from(
        (q['options'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      for (final opt in options) {
        final optImgs = List<String>.from(opt['images'] ?? []);
        for (final url in optImgs) {
          final b64 = await _downloadImageAsBase64(imageUrl: url, cookieHeader: cookieHeader, userAgent: userAgent, onLog: onLog);
          processedImages++;
          onImageProgress?.call(processedImages, totalImages);
          if (b64 != null) currentQuestionBase64List.add(b64);
        }
      }
      final optionsSummary = options.map((o) => '${o['label']}: ${o['text']}').join(' | ');
      contentParts.add({
        'type': 'text',
        'text': '\n【第 ${q['index']} 题】题型: ${q['type']}\n题干: ${q['stem']}\n选项: $optionsSummary'
      });
      for (final b64Uri in currentQuestionBase64List) {
        contentParts.add({'type': 'image_url', 'image_url': {'url': b64Uri}});
      }
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
      return error.message ?? '网络异常';
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