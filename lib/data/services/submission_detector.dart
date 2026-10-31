/// 「这份作业是不是已经交了」的判定规则。
///
/// 全部是**纯函数**：只吃字符串 / 解析好的页面探测结果，不发请求、不碰 WebView，
/// 因此可以直接单测，也方便在别处（例如看板）复用同一套口径。
///
/// 规则来源是 2026-10 真机实测的学习通页面：
///  - 已提交/已批阅的作业打开后是只读视图：
///    `/mooc-ans/mooc2/work/view?...&workId=…&answerId=…&enc=…`
///  - 待作答（动笔前后都是这个地址）：
///    `/mooc-ans/mooc2/work/dowork?...&workId=…&answerId=…`
///  - 老版本作答页：`/mooc2/work/task?...`
///  - 只读视图上会同时出现「我的答案」和「正确答案 / 参考答案」，还带分数。
///
/// **注意**：`answerId` 在作答页上就已经存在，绝对不能拿它当「已交」依据
/// （踩过这个坑：未交作业被误拦）。
library;

/// 页面类型：从地址判断这份作业处于什么状态
enum WorkPageKind {
  /// 已提交的只读视图（`/work/view`）
  submitted,

  /// 待作答（`/work/dowork`、`/work/task`）
  answering,

  /// 看不出来（作业列表页、外链页……），交给页面探测
  unknown,
}

/// 按地址判断页面类型。判不出来就 [WorkPageKind.unknown]。
WorkPageKind workPageKindFromUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return WorkPageKind.unknown;
  final lower = trimmed.toLowerCase();

  if (lower.contains('/work/dowork') || lower.contains('/work/task')) {
    return WorkPageKind.answering;
  }
  if (lower.contains('/work/view')) return WorkPageKind.submitted;
  return WorkPageKind.unknown;
}

/// 按地址判断：是不是已提交的只读视图。
///
/// 这条最稳，页面改版也不影响，所以优先用。
bool urlLooksSubmitted(String url) =>
    workPageKindFromUrl(url) == WorkPageKind.submitted;

/// 按页面探测结果判断：是不是已提交。
///
/// [state] 来自只读 JS 探测，字段：
///  - `questions`：题目块数量
///  - `editable`：可编辑控件数量
///  - `hits`：命中的状态词（已提交 / 已完成 / 待批阅 …）
///  - `answerView`：是否同时出现「我的答案」和「正确答案 / 参考答案」
///  - `score`：页面上是否带分数
///
/// 宁可漏判也不误伤：证据不足一律返回 false，交给后续「没提取到题目」去提示。
bool looksSubmittedFromProbe(Map<String, dynamic> state) {
  final questions = (state['questions'] as num?)?.toInt() ?? 0;
  final editable = (state['editable'] as num?)?.toInt() ?? 0;
  final hits = (state['hits'] ?? '').toString();
  final score = state['score'] == true;
  final answerView = state['answerView'] == true;

  if (answerView) return true; // 「我的答案 + 正确答案」= 批阅后的对答案页
  if (questions <= 0) return false; // 没题目：交给「未提取到题目」处理
  if (editable == 0) return true; // 有题却一个能填的控件都没有 → 只读视图
  if (hits.contains('已完成') && score) return true; // 已批阅
  return false;
}
