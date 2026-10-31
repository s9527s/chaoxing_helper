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

console.log('');
if (failed === 0) {
  console.log('全部通过');
} else {
  console.log(`${failed} 项失败`);
  process.exit(1);
}
