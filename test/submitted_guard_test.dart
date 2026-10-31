import 'package:ai_web_reader/data/services/submission_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「已交作业拦截」的判据测试。
///
/// 真机上两类地址（2026-10 实测）：
///  - 已提交只读：`.../mooc-ans/mooc2/work/view?…&workId=…&answerId=…`
///  - 待作答：    `.../mooc-ans/mooc2/work/dowork?…&workId=…&answerId=…`
/// 两者都带 `answerId`，所以绝不能拿 answerId 当判据（曾把未交作业误拦）。
void main() {
  group('按地址判断是否已提交', () {
    test('已交只读视图（/work/view）判定为已提交', () {
      final url =
          'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/view'
          '?courseId=100008001&classId=100007001&cpi=100009001'
          '&workId=10000600&answerId=10000500&enc=deadbeefdeadbeefdeadbeefdeadbe21';
      expect(urlLooksSubmitted(url), isTrue);
    });

    test('待作答页（/work/dowork 带 answerId）不能误拦', () {
      final url =
          'https://mooc1.chaoxing.com/mooc-ans/mooc2/work/dowork'
          '?courseId=100008001&classId=100007001&cpi=100009001'
          '&workId=10000100&answerId=10000400'
          '&standardEnc=deadbeefdeadbeefdeadbeefdeadbeef'
          '&enc=deadbeefdeadbeefdeadbeefdeadbe22';
      expect(urlLooksSubmitted(url), isFalse);
    });

    test('老版作答页（/mooc2/work/task）不能误拦', () {
      expect(
        urlLooksSubmitted(
          'https://mooc1.chaoxing.com/mooc2/work/task'
          '?courseId=1&classId=2&workId=100&enc=abc',
        ),
        isFalse,
      );
    });

    test('作业列表页不能误拦', () {
      expect(
        urlLooksSubmitted(
          'https://mooc1.chaoxing.com/mooc2/work/list'
          '?courseId=1&classId=2&cpi=3&ut=s&stuenc=abc&enc=def',
        ),
        isFalse,
      );
    });

    test('空地址按「没判断出来」处理', () {
      expect(urlLooksSubmitted(''), isFalse);
      expect(urlLooksSubmitted('   '), isFalse);
      expect(workPageKindFromUrl(''), WorkPageKind.unknown);
    });

    test('地址能区分三种页面类型（决定要不要再做页面探测）', () {
      expect(
        workPageKindFromUrl('https://mooc1.chaoxing.com/mooc-ans/mooc2/work/view?workId=1'),
        WorkPageKind.submitted,
      );
      expect(
        workPageKindFromUrl('https://mooc1.chaoxing.com/mooc-ans/mooc2/work/dowork?workId=1'),
        WorkPageKind.answering,
      );
      expect(
        workPageKindFromUrl('https://mooc1.chaoxing.com/mooc2/work/list?courseId=1'),
        WorkPageKind.unknown,
      );
    });
  });

  group('按页面探测结果判断是否已提交', () {
    test('「我的答案 + 正确答案」对答案视图 → 已交', () {
      expect(
        looksSubmittedFromProbe(<String, dynamic>{
          'questions': 0,
          'editable': 0,
          'hits': '',
          'answerView': true,
          'score': true,
        }),
        isTrue,
      );
    });

    test('有题目但一个可填控件都没有 → 只读视图，已交', () {
      expect(
        looksSubmittedFromProbe(<String, dynamic>{
          'questions': 3,
          'editable': 0,
          'hits': '已完成',
          'answerView': false,
          'score': true,
        }),
        isTrue,
      );
    });

    test('正常的可作答页面不能误拦', () {
      expect(
        looksSubmittedFromProbe(<String, dynamic>{
          'questions': 3,
          'editable': 12,
          'hits': '',
          'answerView': false,
          'score': false,
        }),
        isFalse,
      );
    });

    test('没探测到题目时不下结论（交给「未提取到题目」提示）', () {
      expect(
        looksSubmittedFromProbe(<String, dynamic>{
          'questions': 0,
          'editable': 0,
          'hits': '',
          'answerView': false,
          'score': false,
        }),
        isFalse,
      );
    });
  });
}
