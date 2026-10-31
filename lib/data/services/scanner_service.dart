import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

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
      status.contains('已交') ||
          status.contains('已完成') ||
          status.contains('已提交');

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
  static CourseRef? fromUrl(
    String url, {
    String courseName = '',
  }) {
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
    final preferredHome = _score(otherHome) > _score(mineHome) ? otherHome : mineHome;

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

/// 页面 HTML 解析服务。
///
/// 只做**纯解析**：输入是已经拿到手的 HTML 字符串，输出是任务/课程列表。
/// 本身不发起任何网络请求、不创建 WebView、不加载页面。
/// HTML 的来源要么是每个 frame 自报上来的快照，要么是用户当前正在看的页面。
class ScannerService {
  ScannerService._();

  static final ScannerService instance = ScannerService._();

  /// 我的课程列表（仅作为快捷入口的默认入口地址）
  static const String courseListUrl =
      'https://mooc1.chaoxing.com/visit/interaction';

  /// 状态节点：`<p class="status fl">未交</p>`
  static const String _statusSelector = '.status.fl';

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

  // ---------------- HTML 解析 ----------------

  /// 从一个页面里解析出课程列表（只读 DOM，不点击、不跳转）。
  ///
  /// 「课程入口」批量导入用的就是它：打开学习通课程列表页，
  /// 点一下「保存全部课程」，一次性把整页的课程卡片存成快捷入口。
  List<CourseRef> parseCourseListHtml(String html) => _parseCourseList(html);

  /// 解析「我的课程」列表页。
  ///
  /// 真实 DOM（`https://mooc1.chaoxing.com/visit/interaction`）：
  /// ```html
  /// <a class="color1" href="https://mooc1.chaoxing.com/visit/stucoursemiddle
  ///       ?courseid=100008001&amp;clazzid=100007001&amp;cpi=100009001&amp;ismooc2=1&amp;v=2"
  ///    target="_blank">
  ///   <span class="course-name overHidden2" title="英语四六级">英语四六级</span>
  ///   <i class="icon-news"></i>
  /// </a>
  /// ```
  /// 课程名优先取 `span.course-name` 文本，其次 `title` 属性；
  /// courseId / classId 从 href 的 query 里取（学习通有的是 `courseid`+`clazzid`，
  /// 课程内页用的是 `courseId`+`classId`，这里统一小写比较兼容两种写法）。
  List<CourseRef> _parseCourseList(String html) {
    final document = html_parser.parse(html);
    final courses = <CourseRef>[];
    final seen = <String>{};

    // 主选择器是课程卡片上的 a.color1；页面改版时退化为所有带 courseid 的链接
    var anchors = document.querySelectorAll('a.color1');
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll('a[href*="courseid="]');
    }
    if (anchors.isEmpty) {
      // 新版课程列表没有 a.color1：从课程名节点往上找到最近的课程链接
      anchors = _findAnchorsByCourseName(document);
    }
    if (anchors.isEmpty) {
      // 卡片压根不是 <a>，而是 <li onclick="...stucoursemiddle?courseid=...">
      anchors = _findAnchorsFromOnclick(document);
    }

    for (final anchor in anchors) {
      final href = _normalizeUrl(anchor.attributes['href'] ?? '');
      final ids = _extractCourseIds(href);
      if (ids == null) continue;

      final courseName = _readCourseName(anchor);
      if (courseName.isEmpty) continue;

      // 同一门课在页面上可能出现多次（图标、标题各一个 a）
      if (!seen.add('${ids.$1}|${ids.$2}')) continue;

      courses.add(
        CourseRef(
          courseName: courseName,
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

  /// 兜底：从 `.course-name` 之类的课程名节点往上冒泡，找到包着它的课程链接。
  /// 新版课程列表的 DOM 层级更深，直接选 a 会漏掉。
  List<dom.Element> _findAnchorsByCourseName(dom.Document document) {
    final found = <dom.Element>[];
    final seen = <dom.Element>{};

    for (final node in document.querySelectorAll('[class*="course-name"]')) {
      var current = node.parent;
      while (current != null) {
        if (current.localName == 'a') {
          final href = current.attributes['href'] ?? '';
          if (href.toLowerCase().contains('courseid=') && seen.add(current)) {
            found.add(current);
          }
          break;
        }
        current = current.parent;
      }
    }
    return found;
  }

  /// 兜底：卡片本身不是链接，而是 `<li onclick="location='...courseid=...'">`。
  /// 这里把 onclick 里的地址抽出来，拼成一个合成的 <a>，复用后面的解析逻辑。
  List<dom.Element> _findAnchorsFromOnclick(dom.Document document) {
    final found = <dom.Element>[];
    final seen = <String>{};

    for (final el in document.querySelectorAll('[onclick]')) {
      final onclick = el.attributes['onclick'] ?? '';
      if (!onclick.toLowerCase().contains('courseid=')) continue;

      final match = RegExp(
        r'''['"]([^'"]*courseid=[^'"]*)['"]''',
      ).firstMatch(onclick);
      final href = (match?.group(1) ?? '').trim();
      if (href.isEmpty || !seen.add(href)) continue;

      final anchor = dom.Element.tag('a');
      anchor.attributes['href'] = href;
      anchor.append(el.clone(true));
      found.add(anchor);
    }
    return found;
  }

  /// 课程名：`span.course-name` 文本 → 其 title 属性 → a 的 title → a 的纯文本
  String _readCourseName(dom.Element anchor) {
    final nameNode = anchor.querySelector('span.course-name') ??
        anchor.querySelector('.course-name');

    if (nameNode != null) {
      final text = nameNode.text.trim();
      if (text.isNotEmpty) return text;
      final title = nameNode.attributes['title']?.trim() ?? '';
      if (title.isNotEmpty) return title;
    }

    final anchorTitle = anchor.attributes['title']?.trim() ?? '';
    if (anchorTitle.isNotEmpty) return anchorTitle;

    return anchor.text.trim();
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

  /// 供「可见 WebView 抓取」使用：把当前页面的 outerHTML 直接解析成任务列表。
  /// 绕开作业列表页需要 enc 的问题——页面已经是用户手动打开好的。
  List<HomeworkItem> parseTasksFromHtml(String html, {String courseName = '本页作业'}) {
    final items = _parseCourseTasks(
      CourseRef(courseName: courseName, courseId: '', classId: ''),
      html,
    );
    debugPrint('[Scanner] $courseName: 本页解析出 ${items.length} 条未交作业');
    return items;
  }

  /// 供单元测试直接喂 HTML 片段，避免依赖网络。
  @visibleForTesting
  List<HomeworkItem> parseCourseTasksHtml(
      String html, {
        String courseName = '测试课程',
      }) {
    return _parseCourseTasks(
      CourseRef(courseName: courseName, courseId: '', classId: ''),
      html,
    );
  }

  /// 解析课程作业列表页。
  ///
  /// 真实 DOM（学习通 mooc2 作业列表）：
  /// ```html
  /// <li onclick="goTask(this);" data="https://mooc1.chaoxing.com/.../work/task?courseId=..&amp;workId=..">
  ///   <div class="tag work-icon icon-zy"></div>
  ///   <div class="right-content">
  ///     <p class="overHidden2 fl">作业20260926</p>
  ///     <p class="status fl">未交</p>
  ///   </div>
  /// </li>
  /// ```
  List<HomeworkItem> _parseCourseTasks(CourseRef course, String html) {
    final document = html_parser.parse(html);
    final items = <HomeworkItem>[];
    final seen = <String>{};
    var skippedByStatus = 0;
    var duplicateCount = 0;

    // 只认真正的作业行：学习通的作业 li 带 onclick="goTask(this)" 且 data 里有 workId/exam。
    // 不能退化成"所有 li"或"所有 a[href]"——侧边栏（进入空间/章节/资料/错题集）会被误判成作业。
    var nodes = document.querySelectorAll(
      'li[onclick*="goTask"], li[data*="workId"], li[data*="/work/"], li[data*="/exam/"]',
    );
    if (nodes.isEmpty) {
      // 退化：只接受 data 指向作业/考试的 li，绝不吃侧边栏（/visit/…）菜单
      nodes = document.querySelectorAll('li[data]').where((node) {
        final data = (node.attributes['data'] ?? '').toLowerCase();
        return data.contains('/work') || data.contains('workid') || data.contains('/exam');
      }).toList();
    }

    for (final node in nodes) {
      final rawUrl = node.attributes['data'] ?? '';
      final url = _normalizeUrl(rawUrl);
      if (url.isEmpty) continue;

      // 最后一道闸：地址必须像作业/考试，否则丢弃
      final lowerUrl = url.toLowerCase();
      if (!lowerUrl.contains('/work') &&
          !lowerUrl.contains('workid') &&
          !lowerUrl.contains('/exam')) {
        continue;
      }

      final title = _readTaskTitle(node);
      final statusText = _readTaskStatus(node);

      // ---- 状态过滤：只保留「未交 / 待交」这类待办 ----
      if (statusText.isNotEmpty) {
        if (!_isPendingStatus(statusText)) {
          skippedByStatus++;
          continue;
        }
      } else if (_rowLooksClosed(node.text.replaceAll(RegExp(r'\s+'), ''))) {
        // 页面没有单独的状态节点，但整行文字里写着「待批阅 / 已完成」等
        skippedByStatus++;
        continue;
      }

      // ---- 去重：优先 workId / examId，没有才退化到「标题 + 截止时间」 ----
      // 绝不用整条 URL：列表页每次刷新 URL 上的 answerId/enc 都会变，
      // 同一个作业会被当成两条，看板数量就虚增了。
      final kind = _inferKind(url: url, title: title);
      final displayTitle = title.isEmpty ? kind.label : title;
      final taskKey = _extractTaskKey(url, node);
      final deadline = _tryParseDeadline(node.text);
      final identity = taskKey ??
          'sig:${course.courseName}|$displayTitle|'
              '${deadline?.toIso8601String() ?? ''}';
      if (!seen.add(identity)) {
        duplicateCount++;
        continue;
      }

      items.add(
        HomeworkItem(
          courseName: course.courseName,
          title: displayTitle,
          kind: kind,
          url: url,
          status: statusText.isEmpty ? '未知' : statusText,
          deadline: deadline,
          identity: taskKey,
        ),
      );
    }

    if (skippedByStatus > 0 || duplicateCount > 0) {
      debugPrint(
        '[Scanner] ${course.courseName}: 跳过非待办 $skippedByStatus 条，'
        '去重 $duplicateCount 条，保留 ${items.length} 条',
      );
    }

    return items;
  }

  /// 读取任务状态。不同皮肤分别放在 `.status.fl` / `.status` / `.zt` / `.state` 里。
  String _readTaskStatus(dom.Element node) {
    const selectors = <String>[
      _statusSelector,
      '.status',
      '[class*="status"]',
      '.zt',
      '.state',
      '[class*="state"]',
    ];

    for (final selector in selectors) {
      final el = node.querySelector(selector);
      if (el == null) continue;
      final text = el.text.replaceAll(RegExp(r'\s+'), '');
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /// 是否属于待办状态（未交 / 待交 / 未提交 …）
  bool _isPendingStatus(String status) =>
      _pendingStatusKeywords.any(status.contains);

  /// 没有状态节点时的兜底：整行文字里出现「待批阅 / 已完成」等即视为已结束
  bool _rowLooksClosed(String rowText) =>
      _closedStatusKeywords.any(rowText.contains);

  /// 提取唯一标识：`data-workid` 属性 → URL 里的 workId/examId → 路径里的数字 id。
  /// 网页上重发或多行重复时，同一个 workId 只会保留第一条。
  String? _extractTaskKey(String url, dom.Element node) {
    for (final name in <String>[
      'data-workid',
      'data-work-id',
      'workid',
      'data-examid',
      'examid',
    ]) {
      final value = node.attributes[name]?.trim() ?? '';
      if (value.isNotEmpty) return 'wid:$value';
    }

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

    final match = RegExp(r'/(?:work|exam)/(?:task|test)/(\d+)').firstMatch(uri.path);
    if (match != null) return 'pid:${match.group(1)}';
    return null;
  }

  /// 读取任务标题。
  /// 作业列表页在不同皮肤下结构不同：mooc2 用 `.overHidden2.fl`，
  /// 课程主页的作业页只有「作业 / 作业20261030 / 待批阅」这样的纯文本行，
  /// 所以这里做选择器 + 行文本双重兜底，避免标题退化成类型名。
  String _readTaskTitle(dom.Element node) {
    const selectors = <String>[
      '.overHidden2.fl',
      '.overHidden2',
      '[class*="overHidden"]',
      '.titTxt',
      '.tit',
      '.title',
    ];

    for (final selector in selectors) {
      final el = node.querySelector(selector);
      final text = el?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      if (text.isNotEmpty) return text;
    }

    // 行文本兜底：过滤掉类型徽标与状态词，取第一个像标题的片段
    const noise = <String>{
      '作业', '考试', '任务', '待批阅', '未交', '已交', '已完成',
      '待完成', '进行中', '未开始', '进行中（10）', '暂无',
    };

    final parts = node.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);

    for (final part in parts) {
      if (noise.contains(part)) continue;
      if (RegExp(r'^[\d\s:：/.-]+$').hasMatch(part)) continue;
      return part;
    }

    return '';
  }

  /// 处理 HTML 实体与相对路径：`&amp;` → `&`，`//`、`/` 补全为绝对地址
  String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';

    // html 包通常已解实体，这里兜住二次编码的情况
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
