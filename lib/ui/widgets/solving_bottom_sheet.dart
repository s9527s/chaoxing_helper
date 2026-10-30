import 'package:flutter/material.dart';

enum SolvingStage { idle, extracting, thinking, completed, error }

class SolvingProgressController extends ChangeNotifier {
  SolvingStage stage = SolvingStage.idle;
  int totalCount = 0;
  int solvableCount = 0;
  int currentImageIndex = 0;
  int totalImages = 0;
  String? errorMessage;
  final List<String> logs = [];

  void setStage(SolvingStage newStage, {String? logMessage}) {
    stage = newStage;
    if (logMessage != null) addLog(logMessage);
    notifyListeners();
  }

  void updateQuestionStats(int total, int solvable) {
    totalCount = total; solvableCount = solvable; notifyListeners();
  }

  void updateImageProgress(int current, int total) {
    currentImageIndex = current; totalImages = total; notifyListeners();
  }

  void setError(String message) {
    errorMessage = message; stage = SolvingStage.error; addLog('❌ 错误: $message');
  }

  /// 额外日志出口（页面用它把日志同时打到 logcat）
  void Function(String message)? logSink;

  void addLog(String message) {
    final now = DateTime.now();
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    logs.insert(0, '[$timeStr] $message');
    logSink?.call(message);
    notifyListeners();
  }

  void reset() {
    stage = SolvingStage.idle; currentImageIndex = 0; totalImages = 0;
    errorMessage = null; logs.clear();
    notifyListeners();
  }
}

class SolvingBottomSheet extends StatelessWidget {
  final SolvingProgressController controller;
  final VoidCallback onStartPressed;

  const SolvingBottomSheet({super.key, required this.controller, required this.onStartPressed});

  String _stageTitle(SolvingStage stage) {
    switch (stage) {
      case SolvingStage.idle:
        return controller.totalCount > 0 ? '${controller.totalCount} 道题，可自动作答 ${controller.solvableCount} 道' : '准备就绪（未开始）';
      case SolvingStage.extracting: return '正在读取页面题目...';
      case SolvingStage.thinking: return 'AI 分析中...';
      case SolvingStage.completed: return '参考答案已生成';
      case SolvingStage.error: return '执行中断';
    }
  }

  /// 只有真正在跑的三个阶段才锁按钮，error / completed 必须可点
  bool get _isBusy =>
      controller.stage == SolvingStage.extracting ||
      controller.stage == SolvingStage.thinking;

  String _buttonLabel(SolvingStage stage) {
    switch (stage) {
      case SolvingStage.idle:
        return '提取题目并请求 AI';
      case SolvingStage.extracting:
      case SolvingStage.thinking:
        return '执行中...';
      case SolvingStage.completed:
        return '重新分析';
      case SolvingStage.error:
        return '重试';
    }
  }

  @override

  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                Text(_stageTitle(controller.stage), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 16),
                Container(
                  height: 120, width: double.infinity, padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
                  child: controller.logs.isEmpty
                      ? const Center(child: Text('点击下方按钮：读取页面题目 → 请求 AI → 展示参考答案（不会自动填写）', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)))
                      : ListView.builder(
                    itemCount: controller.logs.length,
                    itemBuilder: (context, index) => Text(controller.logs[index], style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity, height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isBusy
                          ? Colors.grey.shade300
                          : (controller.stage == SolvingStage.error
                              ? const Color(0xFFD32F2F)
                              : Colors.black),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                    ),
                    onPressed: _isBusy ? null : onStartPressed,
                    child: Text(
                      _buttonLabel(controller.stage),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Center(
                  child: Text(
                    '答案仅供参考，请自行核对并在网页中手动作答',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}