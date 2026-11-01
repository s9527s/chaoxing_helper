import 'package:ai_web_reader/data/services/scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这里的入参全部是「网页侧读完 DOM 之后交回来的结构化字段」，
/// 与 `assets/js/page_reader.js` 的输出格式一一对应。
/// 测试里**不再出现任何 HTML 字符串**——Dart 侧已经不接收 HTML。
void main() {
  final service = ScannerService.instance;

  group('课程卡片行 → CourseRef', () {
    test('课程名 + courseId/classId/cpi 全部来自字段', () {
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': '英语四六级',
          'href':
              'https://mooc1.chaoxing.com/visit/stucoursemiddle?courseid=100008001&clazzid=100007001&cpi=100009001&ismooc2=1&v=2',
        },
        <String, dynamic>{
          'name': '高等数学 A',
          'href':
              'https://mooc1.chaoxing.com/visit/stucoursemiddle?courseid=2604&clazzid=1475&cpi=1',
        },
        // 没有 courseid 的链接（侧边栏「进入空间」之类）必须被丢掉
        <String, dynamic>{'name': '无链接课程', 'href': 'javascript:void(0);'},
      ];

      final courses = service.parseCourseRows(rows);

      expect(courses, hasLength(2));
      expect(courses.first.courseName, '英语四六级');
      expect(courses.first.courseId, '100008001');
      expect(courses.first.classId, '100007001');
      expect(courses.first.cpi, '100009001');
      expect(courses.first.enc, isEmpty);

      final url = courses.first.workListUrl;
      expect(url, contains('mooc1.chaoxing.com/mooc2/work/list'));
      expect(url, contains('courseId=100008001'));
      expect(url, contains('classId=100007001'));
      expect(url, contains('cpi=100009001'));
      expect(courses[1].courseName, '高等数学 A');
    });

    test('同一门课出现两次只保留一条，相对地址补全为绝对地址', () {
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': '大学英语',
          'href': '/visit/stucoursemiddle?courseid=77&clazzid=88&cpi=99',
        },
        <String, dynamic>{
          'name': '大学英语（图标重复）',
          'href': '/visit/stucoursemiddle?courseid=77&clazzid=88&cpi=99',
        },
      ];

      final courses = service.parseCourseRows(rows);

      expect(courses, hasLength(1));
      expect(courses.single.courseName, '大学英语');
      expect(courses.single.courseId, '77');
      expect(courses.single.classId, '88');
      expect(courses.single.entryUrl, startsWith('https://mooc1.chaoxing.com/'));
    });

    test('字段类型不对或为空时直接丢弃，不做兜底猜测', () {
      final rows = <dynamic>[
        'not-a-map',
        <String, dynamic>{'name': 123, 'href': 'x?courseid=1&clazzid=2'},
        <String, dynamic>{'name': '   ', 'href': 'x?courseid=1&clazzid=2'},
        <String, dynamic>{
          'name': '数据结构',
          'href': 'https://mooc1.chaoxing.com/visit/stucoursemiddle?courseid=11&clazzid=22',
        },
      ];

      final courses = service.parseCourseRows(rows);
      expect(courses, hasLength(1));
      expect(courses.single.courseName, '数据结构');
    });
  });

  group('作业行 → HomeworkItem', () {
    test('URL 里的参数原样保留，标题/状态来自字段', () {
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '作业20260926',
          'status': '未交',
          'deadline': '',
          'workId': '10000200',
          'examId': '',
          'url':
              'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=100008001&classId=100007001&cpi=100009001&workId=10000200&answerId=10000300&enc=cd51f82928fa',
        },
      ];

      final items = service.parseTaskRows(rows, courseName: '高等数学 A');

      expect(items, hasLength(1));
      final first = items.first;
      expect(first.title, '作业20260926');
      expect(first.status, '未交');
      expect(first.courseName, '高等数学 A');
      expect(first.kind, HomeworkKind.homework);
      expect(first.deadline, isNull, reason: '页面无截止时间应为 null');
      expect(first.hasDeadline, isFalse);
      expect(first.url.contains('&amp;'), isFalse);
      expect(first.url, contains('workId=10000200'));
      expect(first.isSubmitted, isFalse);
      expect(first.identity, 'wid:10000200');
    });

    test('状态过滤：只保留未交/待交，待批阅/已完成/已交全部跳过', () {
      final rows = <Map<String, dynamic>>[
        for (final entry in <String>[
          '未交',
          '待批阅',
          '已完成',
          '已交',
          '待交',
        ])
          <String, dynamic>{
            'title': '作业$entry',
            'status': entry,
            'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=$entry',
          },
        // 没有状态节点，但行文字里写着「待批阅」→ 已结束
        <String, dynamic>{
          'title': '作业F',
          'status': '',
          'text': '作业F 待批阅 2026-09-30',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=F',
        },
        // 没有状态节点、行文字也没写结束词 → 保留
        <String, dynamic>{
          'title': '作业G（无状态节点）',
          'status': '',
          'text': '作业G 2026-09-30',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=G',
        },
      ];

      final items = service.parseTaskRows(rows);
      final titles = items.map((e) => e.title).toList();

      expect(titles, <String>['作业未交', '作业待交', '作业G（无状态节点）']);
      expect(titles, isNot(contains('作业待批阅')));
      expect(titles, isNot(contains('作业已完成')));
      expect(titles, isNot(contains('作业已交')));
      expect(titles, isNot(contains('作业F')));
    });

    test('相同 workId 只保留一条（标题相同或不同都算）', () {
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '作业20260926',
          'status': '未交',
          'workId': '999',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=999',
        },
        <String, dynamic>{
          'title': '作业20260926',
          'status': '未交',
          'workId': '999',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=999',
        },
        <String, dynamic>{
          'title': '作业20260926（重发）',
          'status': '未交',
          'workId': '999',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=999',
        },
        <String, dynamic>{
          'title': '作业20260926',
          'status': '未交',
          'workId': '888',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=888',
        },
      ];

      final items = service.parseTaskRows(rows);

      expect(items, hasLength(2));
      expect(items.first.title, '作业20260926', reason: '重复 workId 保留第一条');
      expect(items.first.url, contains('workId=999'));
      expect(items[1].url, contains('workId=888'));
    });

    test('没有 workId 字段时退回 URL 去重，不会把不同作业合并', () {
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '期中测验',
          'status': '未交',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&examId=7&enc=abc',
        },
        <String, dynamic>{
          'title': '期中测验',
          'status': '未交',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&examId=7&enc=def',
        },
        <String, dynamic>{
          'title': '期末测验',
          'status': '未交',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&examId=8&enc=abc',
        },
      ];

      final items = service.parseTaskRows(rows);

      expect(items, hasLength(2));
      expect(items.first.identity, 'eid:7');
      expect(items[1].identity, 'eid:8');
    });

    test('考试类链接识别为 exam，且带截止时间的能解析出来', () {
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '期中测验',
          'status': '未交',
          'deadline': '2026-11-01 23:59',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/exam/test?courseId=1&examId=9',
        },
      ];

      final items = service.parseTaskRows(rows);

      expect(items, hasLength(1));
      expect(items.first.kind, HomeworkKind.exam);
      expect(items.first.deadline, DateTime(2026, 11, 1, 23, 59));
      expect(items.first.isExpired, isFalse);
      expect(items.first.hoursLeft, greaterThan(0));
    });

    test('字段类型/长度受控：非字符串丢弃、超长截断', () {
      final rows = <dynamic>[
        // 地址不是字符串 → 丢
        <String, dynamic>{'title': '坏行', 'url': 42},
        // 地址不像作业/考试 → 丢
        <String, dynamic>{
          'title': '侧边栏',
          'status': '未交',
          'url': 'https://mooc1.chaoxing.com/visit/interaction',
        },
        // 标题是 Map → 当作空，退化成类型名
        <String, dynamic>{
          'title': <String, dynamic>{'x': 1},
          'status': '未交',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=1',
        },
        // 超长标题 → 截断到 120 字
        <String, dynamic>{
          'title': 'A' * 500,
          'status': '未交',
          'url': 'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?workId=2',
        },
      ];

      final items = service.parseTaskRows(rows);

      expect(items, hasLength(2));
      expect(items.first.title, HomeworkKind.homework.label);
      expect(items[1].title.length, 120);
    });

    test('空列表返回空，不抛异常', () {
      expect(service.parseTaskRows(const <dynamic>[]), isEmpty);
      expect(service.parseCourseRows(const <dynamic>[]), isEmpty);
    });
  });

  test('课程入口：带 enc 的作业列表地址优先级更高', () {
    const fromList = CourseRef(
      courseName: '数据结构',
      courseId: '11',
      classId: '22',
      cpi: '33',
    );
    const fromWorkPage = CourseRef(
      courseName: '',
      courseId: '11',
      classId: '22',
      enc: 'xyz',
      homeUrl:
          'https://mooc1.chaoxing.com/mooc2/work/list?courseId=11&classId=22&enc=xyz',
    );

    final merged = fromList.mergeWith(fromWorkPage);
    expect(merged.courseName, '数据结构');
    expect(merged.enc, 'xyz');
    expect(merged.entryUrl, contains('enc=xyz'));
  });

  test('课程入口：从页面地址反解课程（含 enc）', () {
    final ref = CourseRef.fromUrl(
      'https://mooc1.chaoxing.com/mooc2/work/list?courseId=5&classId=6&cpi=7&enc=8&mooc2=1',
      courseName: '线性代数',
    );

    expect(ref, isNotNull);
    expect(ref!.courseName, '线性代数');
    expect(ref.courseId, '5');
    expect(ref.classId, '6');
    expect(ref.enc, '8');
    expect(ref.entryUrl, contains('enc=8'));

    // 不是课程页的地址直接返回 null
    expect(
      CourseRef.fromUrl('https://mooc1.chaoxing.com/visit/interaction'),
      isNull,
    );
  });
}
