import 'package:ai_web_reader/data/services/scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _workListHtml = '''
<html><body>
<ul class="ulDiv">
  <li onclick="goTask(this);" data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=100008001&amp;classId=100007001&amp;cpi=100009001&amp;workId=10000200&amp;answerId=10000300&amp;enc=deadbeefdeadbeefdeadbeefdeadbe24" onkeydown="if(event.keyCode == 13){goTask(this);}" tabindex="0" aria-label="作业20260926 ; 未交" role="link">
    <div class="tag work-icon icon-zy"></div>
    <div class="right-content">
      <p class="overHidden2 fl">作业20260926</p>
      <div class="clear"></div>
      <p class="status fl">未交</p>
    </div>
    <div class="clearfix"></div>
  </li>
  <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&amp;workId=2" role="link">
    <p class="overHidden2 fl">作业20261001</p>
    <p class="status fl">已交</p>
  </li>
  <li><div class="menu">无 data 的菜单项</div></li>
</ul>
</body></html>
''';

void main() {
  final service = ScannerService.instance;

  test('解析「我的课程」列表：课程名 + courseId/classId', () {
    const html = '''
    <div class="course-list">
      <a class="color1" href="https://mooc1.chaoxing.com/visit/stucoursemiddle?courseid=100008001&amp;clazzid=100007001&amp;cpi=100009001&amp;ismooc2=1&amp;v=2" target="_blank">
        <span class="course-name overHidden2" style="word-break: break-all;" title="英语四六级">英语四六级</span>
        <i class="icon-news"></i>
      </a>
      <a class="color1" href="https://mooc1.chaoxing.com/visit/stucoursemiddle?courseid=2604&amp;clazzid=1475&amp;cpi=1&amp;ismooc2=1&amp;v=2">
        <span class="course-name overHidden2" title="高等数学 A">高等数学 A</span>
      </a>
      <a href="javascript:void(0);"><span class="course-name overHidden2">无链接课程</span></a>
    </div>
    ''';

    final courses = service.parseCourseListHtml(html);

    expect(courses, hasLength(2)); // 无 courseid 的那条被跳过
    expect(courses.first.courseName, '英语四六级');
    expect(courses.first.courseId, '100008001');
    expect(courses.first.classId, '100007001');
    // 主用地址已改为 mooc2 作业列表（老接口返回「温馨提示·无访问权限」）
    final url = courses.first.workListUrl;
    expect(url, contains('mooc1.chaoxing.com/mooc2/work/list'));
    expect(url, contains('courseId=100008001'));
    expect(url, contains('classId=100007001'));
    // 课程链接里的 cpi 必须带上，否则接口会拒绝
    expect(url, contains('cpi=100009001'));
    // 候选地址：课程主页 → mooc2 列表 → 老接口
    expect(courses.first.workListCandidates, hasLength(3));
    expect(courses[1].courseName, '高等数学 A');
  });

  test('解析真实作业列表 HTML：URL 解实体 / 标题 / 状态', () {
    final items = service.parseCourseTasksHtml(_workListHtml, courseName: '高等数学 A');
    // 「已交」那条会被状态过滤掉，只剩「未交」
    expect(items, hasLength(1));

    final first = items.first;
    expect(first.title, '作业20260926');
    expect(first.status, '未交');
    expect(first.courseName, '高等数学 A');
    expect(first.kind, HomeworkKind.homework);
    expect(first.deadline, isNull, reason: '页面无截止时间应为 null');
    expect(first.hasDeadline, isFalse);

    // &amp; 必须解码为 &，且参数完整
    expect(first.url.contains('&amp;'), isFalse);
    expect(first.url, contains('workId=10000200'));
    expect(first.url, contains('courseId=100008001&classId=100007001'));
    expect(first.url.startsWith('https://mooc1.chaoxing.com/'), isTrue);
    expect(first.isSubmitted, isFalse);
  });

  test('状态过滤：只保留未交/待交，待批阅/已完成/已交全部跳过', () {
    const html = '''
    <ul>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=1">
        <p class="overHidden2 fl">作业A</p><p class="status fl">未交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=2">
        <p class="overHidden2 fl">作业B</p><p class="status fl">待批阅</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=3">
        <p class="overHidden2 fl">作业C</p><p class="status fl">已完成</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=4">
        <p class="overHidden2 fl">作业D</p><p class="status fl">已交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=5">
        <p class="overHidden2 fl">作业E</p><p class="status fl">待交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=6">
        <p class="overHidden2 fl">作业F</p><span class="state">待批阅</span>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=7">
        <p class="overHidden2 fl">作业G（无状态节点）</p>
      </li>
    </ul>
    ''';

    final items = service.parseCourseTasksHtml(html);
    final titles = items.map((e) => e.title).toList();

    expect(titles, <String>['作业A', '作业E', '作业G（无状态节点）']);
    // 状态不是「未交」的一律不进来
    expect(titles, isNot(contains('作业B')));
    expect(titles, isNot(contains('作业C')));
    expect(titles, isNot(contains('作业D')));
    expect(titles, isNot(contains('作业F')));
  });

  test('相同 workId 只保留一条（标题相同或不同都算）', () {
    const html = '''
    <ul>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&amp;workId=999">
        <p class="overHidden2 fl">作业20260926</p><p class="status fl">未交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&amp;workId=999">
        <p class="overHidden2 fl">作业20260926</p><p class="status fl">未交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&amp;workId=999">
        <p class="overHidden2 fl">作业20260926（重发）</p><p class="status fl">未交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&amp;workId=888">
        <p class="overHidden2 fl">作业20260926</p><p class="status fl">未交</p>
      </li>
    </ul>
    ''';

    final items = service.parseCourseTasksHtml(html);
    expect(items, hasLength(2));
    expect(items.first.title, '作业20260926', reason: '重复 workId 保留第一条');
    expect(items.first.url, contains('workId=999'));
    expect(items[1].url, contains('workId=888'));
  });

  test('没有 workId 时退回 URL 去重，不会把不同作业合并', () {
    const html = '''
    <ul>
      <li data="https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&amp;examId=7&amp;enc=abc">
        <p class="overHidden2 fl">期中测验</p><p class="status fl">未交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&amp;examId=7&amp;enc=def">
        <p class="overHidden2 fl">期中测验</p><p class="status fl">未交</p>
      </li>
      <li data="https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&amp;examId=8&amp;enc=abc">
        <p class="overHidden2 fl">期末测验</p><p class="status fl">未交</p>
      </li>
    </ul>
    ''';

    final items = service.parseCourseTasksHtml(html);
    // examId=7 的两条签名不同但同一次考试 → 只留一条；examId=8 是另一场
    expect(items, hasLength(2));
    expect(items.first.url, contains('examId=7'));
    expect(items[1].url, contains('examId=8'));
  });

  test('考试类链接识别为 exam，且带截止时间的能解析出来', () {
    const html = '''
    <ul>
      <li data="https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&amp;examId=9">
        <p class="overHidden2 fl">期中测验</p>
        <p class="status fl">未交</p>
        <p class="time">截止时间：2026-11-01 23:59</p>
      </li>
    </ul>
    ''';

    final items = service.parseCourseTasksHtml(html);
    expect(items, hasLength(1));
    expect(items.first.kind, HomeworkKind.exam);
    expect(items.first.deadline, DateTime(2026, 11, 1, 23, 59));
    expect(items.first.isExpired, isFalse);
    expect(items.first.hoursLeft, greaterThan(0));
  });
}
