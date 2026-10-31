import 'package:ai_web_reader/data/services/scanner_service.dart';
import 'package:ai_web_reader/data/services/task_refresh_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一行「未交」+ 一行「已完成」，模拟真实作业列表页
const String _workListHtml = '''
<html><body>
<ul>
  <li onclick="goTask(this);"
      data="https://mooc1.chaoxing.com/mooc2/work/task?courseId=1&amp;classId=2&amp;workId=100">
    <p class="overHidden2 fl">作业20260926</p>
    <p class="status fl">未交</p>
  </li>
  <li onclick="goTask(this);"
      data="https://mooc1.chaoxing.com/mooc2/work/task?courseId=1&amp;classId=2&amp;workId=101">
    <p class="overHidden2 fl">作业20260927</p>
    <p class="status fl">已完成</p>
  </li>
</ul>
</body></html>
''';

/// 全部已交（刷新后这门课应当从看板消失）
const String _allSubmittedHtml = '''
<html><body>
<ul>
  <li onclick="goTask(this);"
      data="https://mooc1.chaoxing.com/mooc2/work/task?courseId=1&amp;classId=2&amp;workId=200">
    <p class="overHidden2 fl">作业20261001</p>
    <p class="status fl">已完成</p>
  </li>
</ul>
</body></html>
''';

HomeworkItem _item(
  String course,
  String title, {
  int workId = 1,
  int courseId = 1,
}) {
  return HomeworkItem(
    courseName: course,
    title: title,
    kind: HomeworkKind.homework,
    url:
        'https://mooc1.chaoxing.com/mooc2/work/task'
        '?courseId=$courseId&classId=2&workId=$workId',
    status: '未交',
  );
}

const CourseRef _mathRef = CourseRef(
  courseName: '高等数学 A',
  courseId: '1',
  classId: '2',
);

void main() {
  group('解析快照：区分「一行都没有」和「全是已交」', () {
    test('两行里一行未交：totalRows=2，pending=1', () {
      final snapshot = ScannerService.instance.parseWorkListSnapshot(
        _workListHtml,
        courseName: '高等数学 A',
      );

      expect(snapshot.totalRows, 2);
      expect(snapshot.pendingCount, 1);
      expect(snapshot.skippedRows, 1);
      expect(snapshot.pending.single.title, '作业20260926');
      expect(snapshot.pending.single.status, '未交');
    });

    test('全是已交：totalRows>0 但 pending 为空 —— 这门课可以移除', () {
      final snapshot = ScannerService.instance.parseWorkListSnapshot(
        _allSubmittedHtml,
        courseName: '高等数学 A',
      );

      expect(snapshot.hasRows, isTrue);
      expect(snapshot.pending, isEmpty);
    });
  });

  group('从课程页里抠作业列表地址', () {
    test('iframe 里的带 stuenc/enc 的地址能被识别并还原实体', () {
      const page = '''
<html><body>
<iframe src="https://mooc1.chaoxing.com/mooc2/work/list?courseId=1&amp;classId=2&amp;cpi=3&amp;ut=s&amp;t=123&amp;stuenc=abc&amp;enc=def"></iframe>
<script>var other = "https://mooc1.chaoxing.com/mooc2/work/list?courseId=1&classId=2&enc=def2";</script>
</body></html>
''';

      final urls = TaskRefreshService.extractWorkListUrls(page);

      expect(urls, hasLength(2));
      expect(urls.first, contains('stuenc=abc'));
      expect(urls.first, contains('&enc=def'));
      expect(urls.first, isNot(contains('&amp;')));
      expect(urls.last, contains('enc=def2'));
    });

    test('没有作业列表地址时返回空（不会瞎猜 URL）', () {
      expect(
        TaskRefreshService.extractWorkListUrls('<html><body>无权限</body></html>'),
        isEmpty,
      );
    });
  });

  group('按课程页隐藏域还原作业列表地址（workEnc 是关键）', () {
    /// 真实课程页里的关键隐藏域（截取一段即可）
    const page = '''
<html><body>
  <input type="hidden" id="courseid"  value="100008001"/>
  <input type="hidden" id="clazzid"   value="100007001"/>
  <input type="hidden" id="cpi" value="100009001"/>
  <input type="hidden" id="enc" name="enc" value="deadbeefdeadbeefdeadbeefdeadbe23"/>
  <input type="hidden" id="t" name="t" value="1793377969435"/>
  <input type="hidden" id="workEnc" name="workEnc" value="deadbeefdeadbeefdeadbeefdeadbe20">
  <a href="javascript:void(0);" title="作业" data-url="https://mooc1.chaoxing.com/mooc2/work/list">
</body></html>
''';

    test('拼出的地址带 ut=s / stuenc / workEnc，和浏览器点页签时一致', () {
      final url = TaskRefreshService.workListUrlFromCoursePage(page, _mathRef);

      expect(url, isNotNull);
      expect(url, startsWith('https://mooc1.chaoxing.com/mooc2/work/list?'));
      expect(url, contains('courseId=1')); // CourseRef 里的 id 优先
      expect(url, contains('classId=2'));
      expect(url, contains('cpi=100009001'));
      expect(url, contains('ut=s'));
      expect(url, contains('t=1793377969435'));
      expect(url, contains('stuenc=deadbeefdeadbeefdeadbeefdeadbe23'));
      expect(url, contains('enc=deadbeefdeadbeefdeadbeefdeadbe20'));
    });

    test('缺 workEnc 时返回 null —— 绝不退回那个必然「无权限」的地址', () {
      const noWorkEnc = '''
<html><body>
  <input type="hidden" id="courseid" value="1"/>
  <input type="hidden" id="clazzid" value="2"/>
  <input type="hidden" id="enc" value="abc"/>
</body></html>
''';
      expect(
        TaskRefreshService.workListUrlFromCoursePage(noWorkEnc, _mathRef),
        isNull,
      );
    });

    test('CourseRef 缺 cpi/enc 时，用页面上的补齐', () {
      const bare = CourseRef(
        courseName: '英语四六级',
        courseId: '11',
        classId: '22',
      );
      final url = TaskRefreshService.workListUrlFromCoursePage(page, bare);

      expect(url, contains('cpi=100009001'));
      expect(url, contains('stuenc=deadbeefdeadbeefdeadbeefdeadbe23'));
    });
  });

  group('刷新结果合并', () {
    test('成功的课程整批覆盖：旧状态全部丢掉', () {
      final cached = <HomeworkItem>[
        _item('高等数学 A', '旧作业', workId: 100),
        _item('英语四六级', '别人的作业', workId: 900, courseId: 9),
      ];
      final fresh = <HomeworkItem>[
        HomeworkItem(
          courseName: '高等数学 A',
          title: '作业20260926',
          kind: HomeworkKind.homework,
          url:
              'https://mooc1.chaoxing.com/mooc2/work/task'
              '?courseId=1&classId=2&workId=100',
          status: '未交',
        ),
      ];

      final next = TaskRefreshService.applyRefresh(
        cached,
        <CourseRefreshOutcome>[
          CourseRefreshOutcome(
            course: _mathRef,
            ok: true,
            pending: fresh,
            totalRows: 1,
          ),
        ],
      );

      // 高数只剩网页上最新那条（旧作业被覆盖，哪怕是同一个 workId）
      expect(
        next.where((e) => e.courseName == '高等数学 A').map((e) => e.title),
        <String>['作业20260926'],
      );
      // 这次没刷新到的课程原样保留
      expect(next.any((e) => e.courseName == '英语四六级'), isTrue);
    });

    test('刷新到 0 条：这门课从看板消失', () {
      final cached = <HomeworkItem>[
        _item('高等数学 A', '作业A', workId: 300),
        _item('英语四六级', '作业B', workId: 900, courseId: 9),
      ];

      final next = TaskRefreshService.applyRefresh(
        cached,
        <CourseRefreshOutcome>[
          const CourseRefreshOutcome(course: _mathRef, ok: true, totalRows: 3),
        ],
      );

      expect(next.any((e) => e.courseName == '高等数学 A'), isFalse);
      expect(next.any((e) => e.courseName == '英语四六级'), isTrue);
    });

    test('刷新失败：旧数据一条都不能少（网络抖动不能清库）', () {
      final cached = <HomeworkItem>[
        _item('高等数学 A', '作业A', workId: 300),
        _item('高等数学 A', '作业B', workId: 301),
      ];

      final next = TaskRefreshService.applyRefresh(
        cached,
        <CourseRefreshOutcome>[
          const CourseRefreshOutcome.failure(_mathRef, '请求超时'),
        ],
      );

      expect(next.length, 2);
      expect(next.map((e) => e.title), containsAll(<String>['作业A', '作业B']));
    });

    test('全部失败：缓存原样返回', () {
      final cached = <HomeworkItem>[_item('高等数学 A', '作业A', workId: 300)];
      final next = TaskRefreshService.applyRefresh(cached, const [
        CourseRefreshOutcome.failure(_mathRef, '网络不可用'),
      ]);

      expect(identical(next, cached), isFalse);
      expect(next.length, 1);
    });

    test('「成功但一行都没解析到」绝不能清库（抓回空壳页面的兜底）', () {
      final cached = <HomeworkItem>[
        _item('高等数学 A', '作业A', workId: 300),
        _item('高等数学 A', '作业B', workId: 301),
      ];

      final next = TaskRefreshService.applyRefresh(
        cached,
        <CourseRefreshOutcome>[
          const CourseRefreshOutcome(course: _mathRef, ok: true, totalRows: 0),
        ],
      );

      expect(next.length, 2);
      expect(next.map((e) => e.title), containsAll(<String>['作业A', '作业B']));
    });

    test('刷新回来的已交/重复行不会进看板', () {
      final duplicated = <HomeworkItem>[
        _item('高等数学 A', '作业A', workId: 300),
        _item('高等数学 A', '作业A（重复）', workId: 300),
        const HomeworkItem(
          courseName: '高等数学 A',
          title: '已交的那条',
          kind: HomeworkKind.homework,
          url:
              'https://mooc1.chaoxing.com/mooc2/work/task'
              '?courseId=1&classId=2&workId=400',
          status: '已交',
        ),
      ];

      final next = TaskRefreshService.applyRefresh(
        const <HomeworkItem>[],
        <CourseRefreshOutcome>[
          CourseRefreshOutcome(
            course: _mathRef,
            ok: true,
            pending: duplicated,
            totalRows: 3,
          ),
        ],
      );

      expect(next.length, 1);
      expect(next.single.title, '作业A');
    });
  });
}
