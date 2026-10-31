import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/cookie_sync_helper.dart';
import '../../core/network/dio_client.dart';
import 'scanner_service.dart';

/// 一门课的刷新结果。
class CourseRefreshOutcome {
  const CourseRefreshOutcome({
    required this.course,
    required this.ok,
    this.pending = const <HomeworkItem>[],
    this.totalRows = 0,
    this.error,
  });

  const CourseRefreshOutcome.failure(this.course, this.error)
    : ok = false,
      pending = const <HomeworkItem>[],
      totalRows = 0;

  final CourseRef course;

  /// 这次请求是否拿到了可判断的作业列表
  final bool ok;

  /// 最新的未交作业（`ok == true` 且为空 → 这门课已经清零，看板要移除它）
  final List<HomeworkItem> pending;

  /// 页面上共有几行作业（含已交）
  final int totalRows;

  /// 失败原因（`ok == false` 时给用户看）
  final String? error;

  String get courseName => course.courseName;

  bool get isEmpty => ok && pending.isEmpty;

  List<String> get scopeKeys => <String>[
    'cid:${course.courseId}|cls:${course.classId}',
  ];
}

/// 「刷新」取数：用**已登录的 Cookie** 把看板里已有课程的作业列表各取一次。
///
/// 安全边界（重要）：
///  1. **只由用户点击触发**，没有任何定时器/后台任务，进程里不存在静默轮询；
///  2. **只请求看板上已有的那几门课**，不做全量课程遍历、不猜 URL；
///  3. 并发上限 3，请求之间串行提交，避免给学习通造成突发压力；
///  4. 只 GET 列表页，不点击、不提交、不改任何状态。
///
/// 解析仍然交给 [ScannerService]（纯函数），本类只负责取 HTML。
class TaskRefreshService {
  TaskRefreshService._();

  static final TaskRefreshService instance = TaskRefreshService._();

  /// 同时在途的课程数
  static const int _maxConcurrent = 3;

  /// 单门课的超时（Dio 全局是 30s，这里再收紧一点）
  static const Duration _perCourseTimeout = Duration(seconds: 20);

  /// 刷新这一批课程。返回顺序与入参一致。
  Future<List<CourseRefreshOutcome>> refreshCourses(
    List<CourseRef> courses, {
    void Function(String message)? onLog,
  }) async {
    if (courses.isEmpty) return const <CourseRefreshOutcome>[];

    final cookie = await CookieSyncHelper.instance.getCookieHeader();
    if (cookie.trim().isEmpty) {
      return courses
          .map((c) => CourseRefreshOutcome.failure(c, '本地没有登录 Cookie，请重新登录'))
          .toList();
    }

    onLog?.call('刷新开始：${courses.length} 门课，并发上限 $_maxConcurrent（仅请求看板已有课程）');

    final results = List<CourseRefreshOutcome?>.filled(courses.length, null);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= courses.length) return;
        results[index] = await _refreshOne(courses[index], onLog: onLog);
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (var i = 0; i < _maxConcurrent && i < courses.length; i++) worker(),
    ]);

    return results
        .map((e) => e ?? CourseRefreshOutcome.failure(courses.first, '刷新被中断'))
        .toList();
  }

  /// 课程入口地址。
  ///
  /// 优先用缓存里的 [CourseRef.homeUrl]（用户真实停留过的页面，带 enc）；
  /// 早期导入的课程可能只有 id、没有 homeUrl，这时按学习通的课程页格式合成一个，
  /// 用 id + enc 打开同一门课，照样能拿到 `#workEnc`。
  static String _entryUrlOf(CourseRef course) {
    final home = course.homeUrl.trim();
    if (home.isNotEmpty) return home;
    if (!course.hasIds) return '';

    final buffer = StringBuffer(
      'https://mooc2-ans.chaoxing.com/mooc2-ans/mycourse/stu',
    )
      ..write('?courseid=${course.courseId}')
      ..write('&clazzid=${course.classId}');
    if (course.cpi.isNotEmpty) buffer.write('&cpi=${course.cpi}');
    if (course.enc.isNotEmpty) buffer.write('&enc=${course.enc}');
    buffer.write('&pageHeader=8&v=2&hideHead=0');
    return buffer.toString();
  }

  Future<CourseRefreshOutcome> _refreshOne(
    CourseRef course, {
    void Function(String message)? onLog,
  }) async {
    final home = _entryUrlOf(course);
    final tried = <String>{};
    String? lastError;
    String? discovered;

    // ---- 第一步：课程页 ----
    // 作业列表的地址必须由课程页里的隐藏域拼出来（尤其 #workEnc）：
    // 少了 enc 参数，服务端一律回「无权限的操作」。
    if (home.isNotEmpty) {
      try {
        tried.add(home);
        final page = await _fetchHtml(home);
        if (page != null && page.isNotEmpty) {
          if (_looksLikeLoginPage(page)) {
            return CourseRefreshOutcome.failure(course, '登录态已失效，请重新登录');
          }
          discovered = workListUrlFromCoursePage(page, course);
          // 兜底：页面里若直接写了带参数的列表链接，也认
          if (discovered == null) {
            final links = extractWorkListUrls(page);
            if (links.isNotEmpty) discovered = links.first;
          }
        }
      } on DioException catch (e) {
        lastError = _describeDioError(e);
      } catch (e) {
        lastError = '$e';
      }
    }

    final urls = <String>[
      // 由课程页拼出的地址优先（只有它带 stuenc + workEnc）
      if (discovered != null && discovered.isNotEmpty) discovered,
      course.workListUrl,
      if (home.isNotEmpty) home,
    ];

    for (final url in urls) {
      if (!tried.add(url)) continue;
      try {
        // Referer 跟着课程页走，和浏览器里点「作业」页签时一致
        final html = await _fetchHtml(url, referer: home);
        if (html == null || html.trim().isEmpty) {
          lastError = '页面为空';
          continue;
        }

        if (_looksLikeLoginPage(html)) {
          lastError = '登录态已失效，请重新登录';
          break;
        }

        final snapshot = ScannerService.instance.parseWorkListSnapshot(
          html,
          courseName: course.courseName,
        );

        if (snapshot.hasRows) {
          onLog?.call(
            '${course.courseName}：${snapshot.totalRows} 行 → '
            '未交 ${snapshot.pendingCount} 条',
          );
          return CourseRefreshOutcome(
            course: course,
            ok: true,
            pending: snapshot.pending,
            totalRows: snapshot.totalRows,
          );
        }

        // 一行作业都没解析到 = 页面没抓对（缺权限 / 只是外壳 / 登录态问题），
        // **绝不能**当成「这门课没有作业」去清空看板。
        if (html.contains('无权限') ||
            html.contains('无访问权限') ||
            html.contains('温馨提示')) {
          lastError = '没有访问权限，请先在 App 里打开一次这门课的作业页';
          continue;
        }

        lastError = '没解析到作业行（页面 ${html.length} 字）';
      } on DioException catch (e) {
        lastError = _describeDioError(e);
      } catch (e) {
        lastError = '$e';
      }
    }

    // 取不到就**保留旧数据**，绝不用「空结果」把看板洗掉
    debugPrint('[Refresh] ${course.courseName} 刷新失败：$lastError');
    onLog?.call('${course.courseName}：刷新失败（${lastError ?? '未知原因'}），保留旧数据');
    return CourseRefreshOutcome.failure(course, lastError ?? '未知原因');
  }

  /// 从课程页里还原出「作业列表」的真实地址。
  ///
  /// 学习通课程页的「作业」页签点下去时，前端 JS（course-stu.js）会拼出：
  /// ```
  /// /mooc2/work/list?courseId=&classId=&cpi=&ut=s&t=&stuenc=<#enc>&enc=<#workEnc>
  /// ```
  /// 其中 `#workEnc` 是页面里的隐藏域，**少了它服务端只回一句「无权限的操作！」**，
  /// 这也是之前直接拼 `/mooc2/work/list` 一直失败的原因。
  /// 这里按同一套规则拼一遍。纯函数，方便单测。
  static String? workListUrlFromCoursePage(String html, CourseRef course) {
    String field(String id) {
      final after = RegExp(
        'id="$id"[^>]*?value="([^"]*)"',
        caseSensitive: false,
      ).firstMatch(html);
      final before = RegExp(
        'value="([^"]*)"[^>]*?id="$id"',
        caseSensitive: false,
      ).firstMatch(html);
      return (after?.group(1) ?? before?.group(1) ?? '').trim();
    }

    final workEnc = field('workEnc');
    if (workEnc.isEmpty) return null;

    final courseId = course.courseId.isNotEmpty
        ? course.courseId
        : field('courseid');
    final classId = course.classId.isNotEmpty
        ? course.classId
        : field('clazzid');
    if (courseId.isEmpty || classId.isEmpty) return null;

    final cpi = course.cpi.isNotEmpty ? course.cpi : field('cpi');
    final pageEnc = field('enc');
    final stuenc = pageEnc.isNotEmpty ? pageEnc : course.enc;
    final t = field('t');

    final buffer = StringBuffer('https://mooc1.chaoxing.com/mooc2/work/list')
      ..write('?courseId=$courseId')
      ..write('&classId=$classId');
    if (cpi.isNotEmpty) buffer.write('&cpi=$cpi');
    buffer.write('&ut=s');
    if (t.isNotEmpty) buffer.write('&t=$t');
    if (stuenc.isNotEmpty) buffer.write('&stuenc=$stuenc');
    buffer.write('&enc=$workEnc');
    return buffer.toString();
  }

  /// 从课程页 HTML 里抠出「作业列表」的真实地址（iframe / JS 变量里的都算）。
  ///
  /// 纯函数，公开给单测用。
  static List<String> extractWorkListUrls(String html) {
    final found = <String>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'''(?:https?:)?//[^\s"'<>\\]*?/mooc2/work/list\?[^\s"'<>\\]+''',
    );

    for (final match in pattern.allMatches(html)) {
      var url = match.group(0)!.replaceAll('&amp;', '&');
      if (url.startsWith('//')) url = 'https:$url';
      if (seen.add(url)) found.add(url);
    }
    return found;
  }

  /// 取一页 HTML（只读 GET），失败返回 null
  Future<String?> _fetchHtml(String url, {String referer = ''}) async {
    final response = await DioClient.instance.dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: true,
        receiveTimeout: _perCourseTimeout,
        validateStatus: (status) => status != null && status < 500,
        headers: <String, dynamic>{
          'Referer': referer.isNotEmpty ? referer : CookieSyncHelper.moocReferer,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );

    if (response.statusCode != 200) return null;
    return response.data;
  }

  /// 被踢回登录页
  bool _looksLikeLoginPage(String html) {
    if (html.contains('passport2.chaoxing.com/login')) return true;
    return html.contains('用户登录') && html.contains('passport');
  }

  String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '请求超时';
      case DioExceptionType.connectionError:
        return '网络不可用';
      default:
        return e.message ?? '请求失败';
    }
  }

  // ---------------- 结果合并（纯函数，可单测） ----------------

  /// 把刷新结果合进缓存。
  ///
  /// 规则：
  ///  1. **只有成功的课程**才允许覆盖；失败的课程原样保留（网络抖动不能清库）；
  ///  2. 「成功」还要求页面上确实解析到过作业行（`totalRows > 0`）——
  ///     否则抓回来的可能只是个空壳页面，不能据此把课程从看板抹掉；
  ///  3. 成功的课程：旧数据整批丢弃，换成最新结果——最新结果是空，就等于这门课
  ///     从看板消失（`_groupByCourse` 不会再生成它的分组）；
  ///  4. 其余课程与旧数据照旧，并顺手按稳定键去重。
  static List<HomeworkItem> applyRefresh(
    List<HomeworkItem> cached,
    List<CourseRefreshOutcome> outcomes,
  ) {
    final succeeded = outcomes
        .where((o) => o.ok && (o.totalRows > 0 || o.pending.isNotEmpty))
        .toList();
    if (succeeded.isEmpty) return List<HomeworkItem>.of(cached);

    final names = <String>{
      for (final outcome in succeeded)
        if (outcome.courseName.trim().isNotEmpty) outcome.courseName.trim(),
    };
    final courseIds = <String>{
      for (final outcome in succeeded)
        if (outcome.course.courseId.trim().isNotEmpty)
          outcome.course.courseId.trim(),
    };

    bool coveredBy(HomeworkItem item) {
      if (names.contains(item.courseName.trim())) return true;
      for (final key in item.courseScopeKeys) {
        if (!key.startsWith('cid:')) continue;
        final cid = key.substring(4).split('|').first;
        if (courseIds.contains(cid)) return true;
      }
      return false;
    }

    final next = <HomeworkItem>[];
    final keys = <String>{};

    for (final old in cached) {
      if (coveredBy(old)) continue;
      if (!old.isPending) continue;
      if (!keys.add(old.stableKey)) continue;
      next.add(old);
    }

    for (final outcome in succeeded) {
      for (final item in outcome.pending) {
        if (!item.isPending) continue;
        if (!keys.add(item.stableKey)) continue;
        next.add(item);
      }
    }

    return next;
  }
}
