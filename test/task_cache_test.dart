import 'dart:convert';

import 'package:ai_web_reader/data/services/scanner_service.dart';
import 'package:ai_web_reader/data/services/task_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

HomeworkItem _item({
  required String course,
  required String title,
  required String workId,
  String status = '未交',
  String? courseId = '100',
  String? classId = '200',
  DateTime? deadline,
}) {
  final query = <String>[
    if (courseId != null) 'courseId=$courseId',
    if (classId != null) 'classId=$classId',
    'workId=$workId',
    // 列表页每次刷新都会带上不同的 answerId，用它验证不会重复计数
    'answerId=0000$workId',
  ].join('&');

  return HomeworkItem(
    courseName: course,
    title: title,
    kind: HomeworkKind.homework,
    url: 'https://mooc1.chaoxing.com/mooc2/work/task?$query',
    status: status,
    deadline: deadline,
    identity: 'wid:$workId',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('待办状态严格过滤', () {
    test('未交 / 待交 算待办，已交 / 待批阅 / 已完成 不算', () {
      expect(HomeworkItem.isPendingStatus('未交'), isTrue);
      expect(HomeworkItem.isPendingStatus('待交'), isTrue);
      expect(HomeworkItem.isPendingStatus('未提交'), isTrue);
      expect(HomeworkItem.isPendingStatus('待提交'), isTrue);

      expect(HomeworkItem.isPendingStatus('已交'), isFalse);
      expect(HomeworkItem.isPendingStatus('已完成'), isFalse);
      expect(HomeworkItem.isPendingStatus('已提交'), isFalse);
      expect(HomeworkItem.isPendingStatus('待批阅'), isFalse);
      expect(HomeworkItem.isPendingStatus('已过期'), isFalse);
      expect(HomeworkItem.isPendingStatus('已截止'), isFalse);
    });

    test('页面没给状态时按待办处理（解析层已排除已结束的行）', () {
      expect(HomeworkItem.isPendingStatus(''), isTrue);
      expect(HomeworkItem.isPendingStatus('未知'), isTrue);
      expect(
        _item(course: 'A', title: 't', workId: '1', status: '未知').isPending,
        isTrue,
      );
    });
  });

  group('稳定去重键', () {
    test('同一个 workId，URL 上 answerId 变了也算同一条', () {
      final a = _item(course: 'A', title: '作业1', workId: '10000200');
      final b = HomeworkItem(
        courseName: 'A',
        title: '作业1',
        kind: HomeworkKind.homework,
        url: 'https://mooc1.chaoxing.com/mooc2/work/task'
            '?courseId=100&classId=200&workId=10000200&answerId=999999',
        status: '未交',
      );
      expect(a.stableKey, b.stableKey);
    });

    test('没有任何 id 时退回「课程+标题+截止时间」，不再用整条 URL', () {
      final deadline = DateTime(2026, 11, 1, 23, 59);
      final a = HomeworkItem(
        courseName: 'A',
        title: '作业1',
        kind: HomeworkKind.homework,
        url: 'https://x/task?answerId=1',
        status: '未交',
        deadline: deadline,
      );
      final b = HomeworkItem(
        courseName: 'A',
        title: '作业1',
        kind: HomeworkKind.homework,
        url: 'https://x/task?answerId=2',
        status: '未交',
        deadline: deadline,
      );
      expect(a.stableKey, b.stableKey);
    });

    test('课程范围键从 URL 抠出 courseId|classId', () {
      final item = _item(course: 'A', title: 't', workId: '1');
      expect(item.courseScopeKeys, <String>['cid:100|cls:200']);
    });
  });

  group('覆盖式合并（每次提取覆盖本地缓存）', () {
    test('同一门课提取后旧数据整批丢弃，其他课程保留', () {
      final cached = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
        _item(course: '高数', title: '作业2', workId: '2'),
        _item(course: '高数', title: '作业3', workId: '3', status: '已交'),
        _item(course: '英语', title: '作业A', workId: '9', courseId: '900'),
      ];

      // 网页最新状态：作业1、作业2 还在，作业3 已交，另多了一条作业4
      final incoming = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
        _item(course: '高数', title: '作业2', workId: '2'),
        _item(course: '高数', title: '作业4', workId: '4'),
        _item(course: '高数', title: '作业3', workId: '3', status: '已交'),
      ];

      final merged = TaskStore.mergeExtraction(cached, incoming);

      final titles =
          merged.items.map((e) => e.title).toList()..sort();
      // 高数只剩网页上的 3 条未交；英语那条没被提取，必须保留
      expect(titles, <String>['作业1', '作业2', '作业4', '作业A']);
      expect(merged.added, 3);
      expect(merged.replaced, 3); // 高数旧缓存 3 条被整批覆盖
      expect(merged.dropped, 1); // 已交那条被过滤
    });

    test('旧缓存里已交的脏数据在读入时就被淘汰，不会参与计数', () {
      final cached = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
        _item(course: '高数', title: '旧脏数据', workId: '7', status: '已完成'),
      ];
      final incoming = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
      ];

      final merged = TaskStore.mergeExtraction(cached, incoming);
      expect(merged.items.length, 1);
      expect(merged.items.single.title, '作业1');
    });

    test('本次全都不是未交时，缓存原样不动（不清空）', () {
      final cached = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
      ];
      final incoming = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1', status: '已交'),
      ];

      final merged = TaskStore.mergeExtraction(cached, incoming);
      expect(merged.added, 0);
      expect(merged.items.length, 1);
      expect(merged.items.single.status, '未交');
    });

    test('课程名猜错也能靠 URL 上的 courseId 认出是同一门课', () {
      final cached = <HomeworkItem>[
        _item(course: '本页作业', title: '作业1', workId: '1'),
      ];
      final incoming = <HomeworkItem>[
        _item(course: '英语四六级', title: '作业2', workId: '2'),
      ];

      final merged = TaskStore.mergeExtraction(cached, incoming);
      expect(merged.items.map((e) => e.title).toList(), <String>['作业2']);
      expect(merged.replaced, 1);
    });

    test('同一次提取里的重复行只留一条', () {
      final incoming = <HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
        _item(course: '高数', title: '作业1', workId: '1'),
      ];

      final merged = TaskStore.mergeExtraction(const <HomeworkItem>[], incoming);
      expect(merged.items.length, 1);
      expect(merged.dropped, 1);
    });
  });

  group('缓存读写的自愈', () {
    test('读到旧版本脏缓存（含已交 / 重复）会清洗并回写', () async {
      final dirty = <Map<String, dynamic>>[
        _item(course: '高数', title: '作业1', workId: '1').toJson(),
        _item(course: '高数', title: '作业1', workId: '1').toJson(), // 重复
        _item(course: '高数', title: '作业2', workId: '2', status: '已交').toJson(),
      ];
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cfg_cached_tasks_v1': jsonEncode(dirty),
      });

      final loaded = await TaskStore.load();
      expect(loaded.length, 1);
      expect(loaded.single.title, '作业1');

      // 已经回写：再读一次还是干净的（脏数据不会赖在缓存里）
      final again = await TaskStore.load();
      expect(again.length, 1);
    });

    test('save 是覆盖写，不会把上一批数据留下来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await TaskStore.save(<HomeworkItem>[
        _item(course: '高数', title: '作业1', workId: '1'),
        _item(course: '高数', title: '作业2', workId: '2'),
      ]);
      await TaskStore.save(<HomeworkItem>[
        _item(course: '高数', title: '作业2', workId: '2'),
      ]);

      final loaded = await TaskStore.load();
      expect(loaded.map((e) => e.title).toList(), <String>['作业2']);
    });
  });
}
