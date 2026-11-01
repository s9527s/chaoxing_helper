import 'package:flutter/foundation.dart';

/// 任务类型：决定点击拦截策略（标准作业可辅助，考试/论文仅提醒）。
enum HomeworkKind {
  homework('标准作业'),
  exam('考试/论文');

  const HomeworkKind(this.label);

  final String label;
}

/// 一条待办任务（由 HTML 解析产出，供看板渲染）。
class HomeworkItem {
  const HomeworkItem({
    required this.courseName,
    required this.title,
    required this.kind,
    required this.url,
    this.status = '未知',
    this.deadline,
    this.identity,
  });

  /// 课程名
  final String courseName;

  /// 任务标题
  final String title;

  /// 任务类型
  final HomeworkKind kind;

  /// 任务页面地址（标准作业进 WebView，考试/论文进外部浏览器）
  final String url;

  /// 页面上的状态文案：未交 / 已交 / 待批阅 …
  final String status;

  /// 截止时间；页面未提供时为 null
  final DateTime? deadline;

  /// 稳定唯一标识（`wid:10000200` / `eid:9`）。同一份作业多次提取时保持一致，
  /// 用于跨次导入去重；页面拿不到 workId 时为 null。
  final String? identity;

  bool get hasDeadline => deadline != null;

  /// 是否已提交（已交 / 已完成）
  bool get isSubmitted =>
      status.contains('已交') || status.contains('已完成') || status.contains('已提交');

  /// 已结束/已失效的状态词：出现任一就绝不是待办
  static const List<String> _closedStatusKeywords = <String>[
    '待批阅',
    '已批阅',
    '批阅中',
    '已交',
    '已完成',
    '已提交',
    '已过期',
    '已结束',
    '已截止',
    '已作废',
    '已撤回',
  ];

  /// 待办状态词：页面明确写着这些就一定是待办
  static const List<String> _pendingStatusKeywords = <String>[
    '未交',
    '待交',
    '未提交',
    '待提交',
    '未完成',
    '待完成',
  ];

  /// **严格**判定这条记录还算不算待办。
  ///
  /// 看板的待办数量只统计 true 的记录，所以这里宁可漏也不要多：
  ///  - 状态里出现「已交 / 待批阅 / 已过期…」→ 直接 false；
  ///  - 状态是「未交 / 待交 / 未提交…」→ true；
  ///  - 页面没给状态（`未知` / 空）→ true，因为解析层已经用整行文本
  ///    排除了「已交」「待批阅」这类行，能走到这里的都是没被标记结束的。
  bool get isPending => isPendingStatus(status);

  /// 状态文案 → 是否待办（供 CourseTask 等外部模型复用，避免重复实现）
  static bool isPendingStatus(String status) {
    final value = status.replaceAll(RegExp(r'\s+'), '');
    if (value.isEmpty || value == '未知') return true;
    if (_closedStatusKeywords.any(value.contains)) return false;
    if (_pendingStatusKeywords.any(value.contains)) return true;
    // 「进行中 / 未开始 / 待完成」等其他未结束状态也保留
    return !value.contains('过期') && !value.contains('结束');
  }

  /// 跨次提取的稳定去重键。
  ///
  /// 不能直接用整条 URL：作业列表每次刷新都会带上新的 answerId / enc，
  /// 同一个作业会以「不同 URL」再次出现，看板数量就会凭空虚增。
  /// 所以优先级是 workId/examId → URL 里的 workId → 课程+标题+截止时间。
  String get stableKey {
    final raw = (identity ?? '').trim();
    if (raw.startsWith('wid:') ||
        raw.startsWith('eid:') ||
        raw.startsWith('pid:') ||
        raw.startsWith('sig:')) {
      return raw;
    }

    final fromUrl = _keyFromUrl(url);
    if (fromUrl != null) return fromUrl;

    return signature;
  }

  /// 兜底签名：课程 + 标题 + 截止时间
  String get signature =>
      'sig:$courseName|$title|${deadline?.toIso8601String() ?? ''}';

  /// 从作业地址里抠 workId / examId（列表页的 URL 上一定有）
  static String? _keyFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    for (final entry in uri.queryParameters.entries) {
      final key = entry.key.toLowerCase();
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      if (key == 'workid' || key == 'work_id') return 'wid:$value';
      if (key == 'examid' || key == 'exam_id') return 'eid:$value';
    }
    return null;
  }

  /// 这条作业属于哪门课（`cid:课程|cls:班级`），用于「本次提取覆盖哪些旧数据」。
  /// URL 上带不出课程信息时返回空列表。
  List<String> get courseScopeKeys {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return const <String>[];

    var courseId = '';
    var classId = '';
    uri.queryParameters.forEach((key, value) {
      switch (key.toLowerCase()) {
        case 'courseid':
          courseId = value.trim();
        case 'clazzid':
        case 'classid':
          classId = value.trim();
      }
    });

    if (courseId.isEmpty) return const <String>[];
    return <String>['cid:$courseId|cls:$classId'];
  }

  /// 序列化（供本地缓存使用）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'courseName': courseName,
    'title': title,
    'kind': kind.name,
    'url': url,
    'status': status,
    'deadline': deadline?.toIso8601String(),
    'identity': identity,
  };

  factory HomeworkItem.fromJson(Map<String, dynamic> json) {
    final rawKind = (json['kind'] ?? '').toString();
    final rawDeadline = (json['deadline'] ?? '').toString();
    final rawIdentity = (json['identity'] ?? '').toString();

    return HomeworkItem(
      courseName: (json['courseName'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      kind: HomeworkKind.values.firstWhere(
        (k) => k.name == rawKind,
        orElse: () => HomeworkKind.homework,
      ),
      url: (json['url'] ?? '').toString(),
      status: (json['status'] ?? '未知').toString(),
      deadline: rawDeadline.isEmpty ? null : DateTime.tryParse(rawDeadline),
      identity: rawIdentity.isEmpty ? null : rawIdentity,
    );
  }

  /// 距离截止的小时数，负数表示已截止；无截止时间时为 null
  int? get hoursLeft {
    final d = deadline;
    if (d == null) return null;
    return d.difference(DateTime.now()).inMinutes ~/ 60;
  }

  bool get isExpired {
    final d = deadline;
    return d != null && !d.isAfter(DateTime.now());
  }

  bool get isUrgent {
    final hours = hoursLeft;
    return hours != null && !isExpired && hours < 24;
  }
}

/// 一次作业列表解析的完整快照。
///
/// 只多记了两个计数，用途很具体：用户点「刷新」时，要把「这门课一条作业都没有」
/// 和「页面上全是已交」区分开——
///  - `totalRows > 0 && pending.isEmpty` → 这门课确实归零了，看板要把它移除；
///  - `totalRows == 0` → 多半是页面没抓到（权限/登录态问题），**不能**据此清库。
class TaskListSnapshot {
  const TaskListSnapshot({
    required this.pending,
    required this.totalRows,
    required this.skippedRows,
  });

  /// 未交/待交的作业（可直接进看板）
  final List<HomeworkItem> pending;

  /// 页面上看起来像作业行的总行数（含已交、已批阅、重复行）
  final int totalRows;

  /// 其中因为「已交/已批阅/重复」被跳过的行数
  final int skippedRows;

  bool get hasRows => totalRows > 0;

  int get pendingCount => pending.length;
}

/// 课程引用：从课程列表页解析出来的最小信息。
class CourseRef {
  const CourseRef({
    required this.courseName,
    required this.courseId,
    required this.classId,
    this.cpi = '',
    this.enc = '',
    this.homeUrl = '',
  });

  final String courseName;
  final String courseId;
  final String classId;

  /// 课程链接里的 cpi，部分接口必须带（缺失会返回「温馨提示·无访问权限」）
  final String cpi;

  /// 课程链接里的 enc（部分页面才带），可为空
  final String enc;

  /// 课程卡片的原始链接（stucoursemiddle…），学习通里它才是能正常打开的入口
  final String homeUrl;

  /// 主用：mooc2 作业列表。
  /// 老接口 /work/getAllWork 现在直接返回「您长时间没有操作，或没有此页面访问权限」。
  String get workListUrl {
    final buffer = StringBuffer('https://mooc1.chaoxing.com/mooc2/work/list')
      ..write('?courseId=$courseId')
      ..write('&classId=$classId');
    if (cpi.isNotEmpty) buffer.write('&cpi=$cpi');
    if (enc.isNotEmpty) buffer.write('&enc=$enc');
    buffer.write('&mooc2=1');
    return buffer.toString();
  }

  /// 去重主键：同一个 courseId + classId 视为同一门课
  String get key => '$courseId|$classId';

  /// 课程卡片链接缺失时（例如从地址栏直接解析 URL），至少还有 id 可用
  bool get hasIds => courseId.isNotEmpty && classId.isNotEmpty;

  /// 快捷入口真正要打开的地址。
  ///
  /// 优先用 homeUrl：它要么来自课程列表页里站点自己生成的卡片链接，
  /// 要么来自用户上次实际停留过的页面（那时 URL 上带着 enc/stuenc，
  /// 直接跳过去就是作业列表，省掉「点进课程→点作业」两步）。
  String get entryUrl => homeUrl.isNotEmpty ? homeUrl : workListUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'courseName': courseName,
    'courseId': courseId,
    'classId': classId,
    'cpi': cpi,
    'enc': enc,
    'homeUrl': homeUrl,
  };

  factory CourseRef.fromJson(Map<String, dynamic> json) => CourseRef(
    courseName: (json['courseName'] ?? '').toString(),
    courseId: (json['courseId'] ?? '').toString(),
    classId: (json['classId'] ?? '').toString(),
    cpi: (json['cpi'] ?? '').toString(),
    enc: (json['enc'] ?? '').toString(),
    homeUrl: (json['homeUrl'] ?? '').toString(),
  );

  /// 从一个学习通页面地址里反解出课程引用。
  ///
  /// 用于「用户手动进到某门课的作业列表页再点提取」时把这门课记下来：
  /// 页面 URL 上带什么参数就存什么（含 enc / stuenc），下次直接跳过去。
  /// 拿不到 courseId + classId 时返回 null。
  static CourseRef? fromUrl(String url, {String courseName = ''}) {
    if (url.trim().isEmpty) return null;

    final uri = Uri.tryParse(_decodeEntities(url.trim()));
    if (uri == null) return null;

    String? courseId;
    String? classId;
    var cpi = '';
    var enc = '';

    uri.queryParameters.forEach((key, value) {
      if (value.isEmpty) return;
      switch (key.toLowerCase()) {
        case 'courseid':
          courseId = value;
        case 'clazzid':
        case 'classid':
          classId = value;
        case 'cpi':
          cpi = value;
        case 'enc':
        case 'stuenc':
          enc = value;
      }
    });

    if (courseId == null || classId == null) return null;

    return CourseRef(
      courseName: courseName,
      courseId: courseId!,
      classId: classId!,
      cpi: cpi,
      enc: enc,
      homeUrl: url.trim(),
    );
  }

  static String _decodeEntities(String raw) =>
      raw.replaceAll('&amp;', '&').replaceAll('&#38;', '&');

  /// 合并两门课的信息，谁有谁的。
  ///
  /// 场景：课程列表页批量导入时拿到了课程名和 cpi（但没有 enc），
  /// 后来用户手动进了这门课的作业列表页，又拿到了带 enc 的 URL。
  /// 两次合并后，快捷入口就能直接跳到作业列表。
  CourseRef mergeWith(CourseRef other) {
    // 保留信息量更大的那个地址：带 enc 的优先（它能直接打开作业列表）
    final mineHome = homeUrl;
    final otherHome = other.homeUrl;
    final preferredHome = _score(otherHome) > _score(mineHome)
        ? otherHome
        : mineHome;

    return CourseRef(
      courseName: other.courseName.isNotEmpty ? other.courseName : courseName,
      courseId: other.courseId.isNotEmpty ? other.courseId : courseId,
      classId: other.classId.isNotEmpty ? other.classId : classId,
      cpi: cpi.isNotEmpty ? cpi : other.cpi,
      enc: enc.isNotEmpty ? enc : other.enc,
      homeUrl: preferredHome,
    );
  }

  /// 地址可用性打分：带 enc 的作业列表页 > 普通课程主页 > 空
  static int _score(String url) {
    if (url.isEmpty) return 0;
    final lower = url.toLowerCase();
    if (lower.contains('enc=') || lower.contains('stuenc=')) return 3;
    if (lower.contains('/work/') || lower.contains('workid=')) return 2;
    return 1;
  }
}

/// 结构化页面数据 → 领域模型的转换服务。
///
/// **不再接收任何 HTML 字符串。** 网页侧（`assets/js/page_reader.js`）在用户
/// 点击按钮后，直接从 DOM 里挑出几个可见字段，拼成 JSON 数组交给这里；
/// 本类只做「字段校验 → 状态过滤 → 去重 → 类型判定 → 截止时间解析」，
/// 不解析标签、不碰隐藏域、不碰 Cookie。
///
/// 本身不发起任何网络请求、不创建 WebView、不加载页面。
class ScannerService {
  ScannerService._();

  static final ScannerService instance = ScannerService._();

  /// 我的课程列表（仅作为快捷入口的默认入口地址）
  static const String courseListUrl =
      'https://mooc1.chaoxing.com/visit/interaction';

  /// 只有命中这些状态词才算「待办」，其余（待批阅 / 已完成 / 已交 …）一律跳过
  static const List<String> _pendingStatusKeywords = <String>[
    '未交',
    '待交',
    '未提交',
    '待提交',
    '未完成',
    '待完成',
  ];

  /// 没有状态节点时，用整行文本兜底排除「已结束」的任务
  static const List<String> _closedStatusKeywords = <String>[
    '待批阅',
    '已批阅',
    '已交',
    '已完成',
    '已提交',
    '已过期',
    '已结束',
    '已截止',
    '已作废',
  ];

  /// 截止时间识别：`2026-09-30 23:59` / `2026/9/30` / `2026年9月30日`
  static final RegExp _deadlinePattern = RegExp(
    r'(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2}))?',
  );

  // ---------------- 结构化数据入口（HTML 不进入 Dart） ----------------

  /// 把网页里读出来的课程卡片（纯文本 + 链接）转成 [CourseRef]。
  ///
  /// 入参来自 `assets/js/page_reader.js` 的 `courses()`，每项只有两个字段：
  /// `name`（可见文字）与 `href`（卡片链接）。**没有 HTML 字符串**——
  /// HTML 解析、DOM 遍历、隐藏字段读取都已经不在 Dart 侧发生。
  List<CourseRef> parseCourseRows(List<dynamic> rows) {
    final courses = <CourseRef>[];
    final seen = <String>{};

    for (final raw in rows) {
      if (raw is! Map) continue;

      final name = _cleanField(raw['name'], 60);
      if (name.isEmpty) continue;

      final href = _normalizeUrl(_cleanField(raw['href'], 1024));
      final ids = _extractCourseIds(href);
      if (ids == null) continue;

      // 同一门课在页面上可能出现多次（图标、标题各一个 a）
      if (!seen.add('${ids.$1}|${ids.$2}')) continue;

      courses.add(
        CourseRef(
          courseName: name,
          courseId: ids.$1,
          classId: ids.$2,
          cpi: ids.$3,
          enc: ids.$4,
          homeUrl: href,
        ),
      );
    }

    return courses;
  }

  /// 从链接里提取 courseId / classId，缺任一则返回 null
  /// 从课程链接里提取 (courseId, classId, cpi, enc)
  (String, String, String, String)? _extractCourseIds(String href) {
    if (href.isEmpty) return null;

    final uri = Uri.tryParse(href);
    if (uri == null) return null;

    String? courseId;
    String? classId;
    var cpi = '';
    var enc = '';

    uri.queryParameters.forEach((key, value) {
      final normalizedKey = key.toLowerCase();
      if (value.isEmpty) return;
      if (normalizedKey == 'courseid') {
        courseId = value;
      } else if (normalizedKey == 'clazzid' || normalizedKey == 'classid') {
        classId = value;
      } else if (normalizedKey == 'cpi') {
        cpi = value;
      } else if (normalizedKey == 'enc') {
        enc = value;
      }
    });

    if (courseId == null || classId == null) return null;
    return (courseId!, classId!, cpi, enc);
  }

  /// 把网页里读出来的作业行（纯文本 + 链接）转成 [HomeworkItem]。
  ///
  /// 入参来自 `assets/js/page_reader.js` 的 `tasks()`，每项最多 7 个字段：
  /// `title` / `status` / `deadline`（可见文字）、`workId` / `examId`（data 属性）、
  /// `url`（行上的 data 链接）、`text`（仅在没有状态节点时给的截断行文本）。
  ///
  /// 这里不做任何标签解析：URL 用 [Uri] 拆参，日期用正则从一小段文本里取。
  List<HomeworkItem> parseTaskRows(
    List<dynamic> rows, {
    String courseName = '本页作业',
  }) {
    final items = <HomeworkItem>[];
    final seen = <String>{};
    var skippedByStatus = 0;
    var duplicateCount = 0;

    for (final raw in rows) {
      if (raw is! Map) continue;

      final url = _normalizeUrl(_cleanField(raw['url'], 1024));
      if (url.isEmpty) continue;

      // 最后一道闸：地址必须像作业/考试，否则丢弃
      final lowerUrl = url.toLowerCase();
      if (!lowerUrl.contains('/work') &&
          !lowerUrl.contains('workid') &&
          !lowerUrl.contains('/exam')) {
        continue;
      }

      final title = _cleanField(raw['title'], 120);
      final status =
          _cleanField(raw['status'], 24).replaceAll(RegExp(r'\s+'), '');
      final rowText =
          _cleanField(raw['text'], 200).replaceAll(RegExp(r'\s+'), '');

      // ---- 状态过滤：只保留「未交 / 待交」这类待办 ----
      if (status.isNotEmpty) {
        if (!_isPendingStatus(status)) {
          skippedByStatus++;
          continue;
        }
      } else if (rowText.isNotEmpty && _rowLooksClosed(rowText)) {
        // 页面没有单独的状态节点，但行文字里写着「待批阅 / 已完成」等
        skippedByStatus++;
        continue;
      }

      // ---- 去重：优先 workId / examId，没有才退化到「标题 + 截止时间」 ----
      final kind = _inferKind(url: url, title: title);
      final displayTitle = title.isEmpty ? kind.label : title;
      final taskKey = _taskKeyOf(
        workId: _cleanField(raw['workId'], 32),
        examId: _cleanField(raw['examId'], 32),
        url: url,
      );
      final deadline = _tryParseDeadline(_cleanField(raw['deadline'], 32));
      final identity =
          taskKey ??
          'sig:$courseName|$displayTitle|'
              '${deadline?.toIso8601String() ?? ''}';
      if (!seen.add(identity)) {
        duplicateCount++;
        continue;
      }

      items.add(
        HomeworkItem(
          courseName: courseName,
          title: displayTitle,
          kind: kind,
          url: url,
          status: status.isEmpty ? '未知' : status,
          deadline: deadline,
          identity: taskKey,
        ),
      );
    }

    if (skippedByStatus > 0 || duplicateCount > 0) {
      debugPrint(
        '[Scanner] $courseName: 跳过非待办 $skippedByStatus 条，'
        '去重 $duplicateCount 条，保留 ${items.length} 条',
      );
    }

    return items;
  }

  /// 是否属于待办状态（未交 / 待交 / 未提交 …）
  bool _isPendingStatus(String status) =>
      _pendingStatusKeywords.any(status.contains);

  /// 没有状态节点时的兜底：整行文字里出现「待批阅 / 已完成」等即视为已结束
  bool _rowLooksClosed(String rowText) =>
      _closedStatusKeywords.any(rowText.contains);

  /// 提取唯一标识：workId → examId → URL 里的 workId/examId → 路径里的数字 id。
  ///
  /// 网页上重发或多行重复时，同一个 workId 只会保留第一条。
  String? _taskKeyOf({
    required String workId,
    required String examId,
    required String url,
  }) {
    if (workId.isNotEmpty) return 'wid:$workId';
    if (examId.isNotEmpty) return 'eid:$examId';

    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    String? weak; // answerId 只作最后兜底（每份作答记录唯一）
    for (final entry in uri.queryParameters.entries) {
      final key = entry.key.toLowerCase();
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      if (key == 'workid' || key == 'work_id') return 'wid:$value';
      if (key == 'examid' || key == 'exam_id') return 'eid:$value';
      if (key == 'answerid' || key == 'answer_id') weak ??= 'aid:$value';
    }
    if (weak != null) return weak;

    final match = RegExp(r'/(?:work|exam)/(?:task|test)/(\d+)')
        .firstMatch(uri.path);
    if (match != null) return 'pid:${match.group(1)}';
    return null;
  }

  /// 字段清洗：非字符串一律丢弃，压缩空白并截断，避免超长内容进内存/日志
  static String _cleanField(dynamic value, int max) {
    if (value is! String) return '';
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > max ? text.substring(0, max) : text;
  }

  /// 处理相对路径与历史遗留的实体编码：`&amp;` → `&`，`//`、`/` 补全为绝对地址
  String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';

    // 少数皮肤把地址写在属性里时仍然带实体，这里兜住
    url = url.replaceAll('&amp;', '&').replaceAll('&#38;', '&');
    // 去掉包裹的引号
    if ((url.startsWith('"') && url.endsWith('"')) ||
        (url.startsWith("'") && url.endsWith("'"))) {
      url = url.substring(1, url.length - 1);
    }

    if (url.startsWith('//')) {
      return 'https:$url';
    }
    if (url.startsWith('/')) {
      return 'https://mooc1.chaoxing.com$url';
    }
    return url;
  }

  /// 依据地址与标题判断任务类型
  HomeworkKind _inferKind({required String url, required String title}) {
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('/exam/') ||
        lowerUrl.contains('examid=') ||
        lowerUrl.contains('test/test')) {
      return HomeworkKind.exam;
    }
    if (title.contains('考试') ||
        title.contains('测验') ||
        title.contains('讨论') ||
        title.contains('论文')) {
      return HomeworkKind.exam;
    }
    return HomeworkKind.homework;
  }

  /// 页面上没有截止时间时返回 null
  DateTime? _tryParseDeadline(String text) {
    final match = _deadlinePattern.firstMatch(text);
    if (match == null) return null;

    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    // 没有具体时分时默认按当天 23:59 截止
    final hour = int.tryParse(match.group(4) ?? '') ?? 23;
    final minute = int.tryParse(match.group(5) ?? '') ?? 59;

    return DateTime(year, month, day, hour, minute);
  }
}
