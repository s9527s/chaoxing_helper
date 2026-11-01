/**
 * extractor.js 的回归测试（Node + jsdom）。
 *
 * 一次性准备：
 *   npm install jsdom
 *
 * 运行：
 *   node tool/test_extractor.js
 *
 * 重点验证两件事：
 *  1. 同一个大题里的多个空，只能算「一题」，绝不能重复出现题干；
 *  2. 脚本对页面是只读的——执行前后 DOM 指纹完全一致。
 */
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const scriptPath = path.resolve(__dirname, '..', 'assets', 'js', 'extractor.js');
const source = fs.readFileSync(scriptPath, 'utf8');

let failed = 0;

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  const mark = ok ? '  PASS' : '  FAIL';
  console.log(`${mark}  ${name}`);
  if (!ok) {
    console.log(`        期望: ${JSON.stringify(expected)}`);
    console.log(`        实际: ${JSON.stringify(actual)}`);
  }
}

/** 在给定 HTML 里跑一遍 extractor.js，返回它抛给 Flutter 的 payload */
function run(html) {
  const dom = new JSDOM(`<!DOCTYPE html><body>${html}</body>`, {
    runScripts: 'outside-only',
  });

  let captured = null;
  dom.window.flutter_inappwebview = {
    callHandler: (name, payload) => {
      if (name === 'onQuestionsExtracted') captured = payload;
    },
  };

  dom.window.eval(source);

  const fingerprint = {
    inputs: dom.window.document.querySelectorAll('input, textarea').length,
    // 只读检查：input 里的值一个都不能被改
    values: Array.from(
      dom.window.document.querySelectorAll('input, textarea')
    ).map((el) => el.value),
    htmlLength: dom.window.document.documentElement.outerHTML.length,
  };

  return { payload: captured, fingerprint };
}

console.log('— 一个大题 + 多个空 —');
{
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">填空题：请在横线处填入正确的单词。</div>
      <div class="questionLi"><div class="Zy_TItle">填空题：请在横线处填入正确的单词。</div><input type="text" value=""></div>
      <div class="questionLi"><div class="Zy_TItle">填空题：请在横线处填入正确的单词。</div><input type="text" value=""></div>
      <div class="questionLi"><div class="Zy_TItle">填空题：请在横线处填入正确的单词。</div><input type="text" value=""></div>
    </div>`;
  const { payload } = run(html);
  check('只算 1 道题', payload.totalCount, 1);
  check('子块被折叠 3 个', payload.collapsedCount, 3);
  check('识别为填空', payload.questions[0].type, 'fill');
  check('空的数量 = 3', payload.questions[0].blankCount, 3);
  check(
    '题干只出现一次',
    payload.questions.map((q) => q.stem),
    ['填空题：请在横线处填入正确的单词。']
  );
}

console.log('— 三道独立单选题 —');
{
  const html = `
    <div class="TiMu"><div class="Zy_TItle">1 + 1 = ?</div>
      <ul class="Zy_ulTop"><li>A. 1</li><li>B. 2</li></ul></div>
    <div class="TiMu"><div class="Zy_TItle">2 + 2 = ?</div>
      <ul class="Zy_ulTop"><li>A. 3</li><li>B. 4</li></ul></div>
    <div class="TiMu"><div class="Zy_TItle">3 + 3 = ?</div>
      <ul class="Zy_ulTop"><li>A. 5</li><li>B. 6</li></ul></div>`;
  const { payload } = run(html);
  check('互不嵌套时保留 3 道', payload.totalCount, 3);
  check('没有子块被折叠', payload.collapsedCount, 0);
  check(
    '题干互不重复',
    payload.questions.map((q) => q.stem),
    ['1 + 1 = ?', '2 + 2 = ?', '3 + 3 = ?']
  );
}

console.log('— 题干完全相同的重复块 —');
{
  const html = `
    <div class="TiMu"><div class="Zy_TItle">单选题：选 C。</div>
      <ul class="Zy_ulTop"><li>C</li></ul></div>
    <div class="TiMu"><div class="Zy_TItle">单选题：选 C。</div>
      <ul class="Zy_ulTop"><li>C</li></ul></div>`;
  const { payload } = run(html);
  check('合并成 1 道', payload.totalCount, 1);
  check('重复的选项也合并掉', payload.questions[0].options.length, 1);
}

console.log('— 大题里选项重复 —');
{
  const html = `
    <div class="TiMu"><div class="Zy_TItle">多选题：选 AB。</div>
      <div class="questionLi"><ul class="Zy_ulTop"><li>A</li><li>B</li></ul></div>
      <div class="questionLi"><ul class="Zy_ulTop"><li>A</li><li>B</li></ul></div>
    </div>`;
  const { payload } = run(html);
  check('只算 1 道', payload.totalCount, 1);
  check('选项去重后剩 2 个', payload.questions[0].options.length, 2);
  check(
    '选项重新编号为 A/B',
    payload.questions[0].options.map((o) => o.label),
    ['A', 'B']
  );
}

console.log('— 两道独立简答题（各自题干 + 独立编辑器）—');
{
  // 真实页面上「简答题（10分）」这类类型标签排在真题干前面，
  // 旧逻辑取第一个命中的节点，两题拿到同一个题干后被当成重复合并，第二题丢失。
  const html = `
    <div class="TiMu">
      <div class="mark_name">简答题（10分）</div>
      <div class="Zy_TItle">第一题：请简述 TCP 三次握手的过程。</div>
      <div class="questionLi">
        <div class="mark_name">简答题（10分）</div>
        <div class="edui-body">作答区</div>
      </div>
    </div>
    <div class="TiMu">
      <div class="mark_name">简答题（10分）</div>
      <div class="Zy_TItle">第二题：请说明 HTTPS 的加密流程。</div>
      <div class="questionLi">
        <div class="mark_name">简答题（10分）</div>
        <div class="edui-body">作答区</div>
      </div>
    </div>`;
  const { payload } = run(html);
  check('两道题都要保留', payload.totalCount, 2);
  check('题干取真题干而不是类型标签', payload.questions.map((q) => q.stem), [
    '第一题：请简述 TCP 三次握手的过程。',
    '第二题：请说明 HTTPS 的加密流程。',
  ]);
  check('编号连续', payload.questions.map((q) => q.index), [1, 2]);
}

console.log('— 两道作文题（题干只有类型标签，正文在块内）—');
{
  const html = `
    <div class="TiMu">
      <div class="mark_name">作文题（20分）</div>
      <div class="body">以 My Hometown 为题写一篇 120 词的作文。</div>
      <div class="questionLi"><div class="mark_name">作文题（20分）</div></div>
    </div>
    <div class="TiMu">
      <div class="mark_name">作文题（20分）</div>
      <div class="body">以 My Dream 为题写一篇 120 词的作文。</div>
      <div class="questionLi"><div class="mark_name">作文题（20分）</div></div>
    </div>`;
  const { payload } = run(html);
  check('两道题都要保留', payload.totalCount, 2);
  check(
    '只有类型标签时用正文兜底，两题可区分',
    payload.questions.map((q) => q.stem),
    [
      '以 My Hometown 为题写一篇 120 词的作文。',
      '以 My Dream 为题写一篇 120 词的作文。',
    ]
  );
}

console.log('— 分组容器 + 两道子题 —');
{
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">二、简答题</div>
      <div class="questionLi">
        <div class="Zy_TItle">（1）什么是三次握手？</div>
        <textarea></textarea>
      </div>
      <div class="questionLi">
        <div class="Zy_TItle">（2）四次挥手为什么要多一次？</div>
        <textarea></textarea>
      </div>
    </div>`;
  const { payload } = run(html);
  check('容器本身不出题，子题各自成条', payload.totalCount, 2);
  check('题干是子题自己的', payload.questions.map((q) => q.stem), [
    '（1）什么是三次握手？',
    '（2）四次挥手为什么要多一次？',
  ]);
}

console.log('— 学习通真实结构：<div class="TiMu questionLi"> —');
{
  const html = `
    <div class="TiMu questionLi">
      <div class="Zy_TItle">1. 翻译：The quick brown fox jumps over the lazy dog.</div>
      <div class="edui-body">作答区</div>
    </div>
    <div class="TiMu questionLi">
      <div class="Zy_TItle">2. 翻译：Practice makes perfect.</div>
      <div class="edui-body">作答区</div>
    </div>`;
  const { payload } = run(html);
  check('同一元素双 class 不会被当成 4 条', payload.totalCount, 2);
  check('两题题干各自独立', payload.questions.map((q) => q.stem), [
    '1. 翻译：The quick brown fox jumps over the lazy dog.',
    '2. 翻译：Practice makes perfect.',
  ]);
}

console.log('— 嵌套 TiMu：分组标题里套两个独立大题 —');
{
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">三、写作</div>
      <div class="TiMu"><div class="Zy_TItle">（1）写一封求职信。</div><textarea></textarea></div>
      <div class="TiMu"><div class="Zy_TItle">（2）写一份会议通知。</div><textarea></textarea></div>
    </div>`;
  const { payload } = run(html);
  check('两个子大题都要出来', payload.totalCount, 2);
  check('外层分组标题不单独成题', payload.questions.map((q) => q.stem), [
    '（1）写一封求职信。',
    '（2）写一份会议通知。',
  ]);
}

console.log('— 题型判定：先看控件，再看题干前缀 —');
{
  // 单选题的选项文本里出现「多选」，旧实现全文 indexOf 会把它判成多选
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">下列关于「多选」的说法，正确的是？</div>
      <ul class="Zy_ulTop"><li>A. 多选只能选一个</li><li>B. 多选可选多个</li></ul>
      <input type="radio" name="q1">
    </div>`;
  const { payload } = run(html);
  check('正文出现「多选」但只有 radio → 单选', payload.questions[0].type, 'single');
}

{
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">1. 下列哪些属于操作系统？</div>
      <ul class="Zy_ulTop"><li>A. Linux</li><li>B. Word</li></ul>
      <input type="checkbox" name="q2">
    </div>`;
  const { payload } = run(html);
  check('勾选框 → 多选', payload.questions[0].type, 'multiple');
}

{
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">判断题：地球是圆的。</div>
      <input type="radio" name="q3">
    </div>`;
  const { payload } = run(html);
  check('radio + 题干前缀「判断」→ 判断', payload.questions[0].type, 'judge');
}

console.log('— 只读性检查 —');
{
  const html = `
    <div class="TiMu"><div class="Zy_TItle">单选题</div>
      <input type="text" value="初始值">
      <textarea>草稿</textarea>
      <ul class="Zy_ulTop"><li>A</li></ul>
    </div>`;
  const { fingerprint } = run(html);
  check('input/textarea 数量不变', fingerprint.inputs, 2);
  check('原有输入值没被改动', fingerprint.values, ['初始值', '草稿']);
}


console.log('— 隐藏内容不外泄 —');
{
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">1. 下列哪个是质数？</div>
      <ul class="Zy_ulTop"><li>A. 4</li><li>B. 7</li></ul>
      <div class="mark_answer" style="display:none">正确答案：B</div>
      <div style="display:none">学生姓名：张三 学号 20230001</div>
      <div aria-hidden="true">aria 隐藏提示</div>
      <script>var answerKey = 'SCRIPT-SECRET';</script>
      <input type="hidden" name="workEnc" value="SECRET-WORK-ENC">
    </div>`;
  const { payload } = run(html);
  const serialized = JSON.stringify(payload);
  check('题干正常取到', payload.questions[0].stem, '1. 下列哪个是质数？');
  check('选项正常取到', payload.questions[0].options.map((o) => o.text), ['A. 4', 'B. 7']);
  check('隐藏的正确答案没有被带出来', serialized.indexOf('正确答案：B') === -1, true);
  check('隐藏的个人信息没有被带出来', serialized.indexOf('20230001') === -1, true);
  check('aria-hidden 文字没有被带出来', serialized.indexOf('aria 隐藏提示') === -1, true);
  check('script 内容没有被带出来', serialized.indexOf('SCRIPT-SECRET') === -1, true);
  check('隐藏表单字段没有被带出来', serialized.indexOf('SECRET-WORK-ENC') === -1, true);
}

{
  // 题干只有类型标签时走 fallbackStem：同样不能把隐藏的答案区读进来
  const html = `
    <div class="TiMu">
      <div class="Zy_TItle">简答题（10分）</div>
      <div class="qtContent">请简述 TCP 三次握手的过程。</div>
      <div style="display:none">参考答案：先 SYN 再 SYN+ACK 最后 ACK</div>
      <textarea></textarea>
    </div>`;
  const { payload } = run(html);
  const stem = payload.questions[0].stem;
  check('正文兜底取到可见正文', stem.indexOf('TCP 三次握手') !== -1, true);
  check('正文兜底不含隐藏的参考答案', stem.indexOf('参考答案') === -1, true);
}

console.log('');
if (failed === 0) {
  console.log('全部通过');
} else {
  console.log(`${failed} 项失败`);
  process.exit(1);
}
