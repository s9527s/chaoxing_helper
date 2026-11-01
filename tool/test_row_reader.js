/**
 * page_reader.js 的回归测试（Node + jsdom）。
 *
 * 运行：
 *   node tool/test_row_reader.js
 *
 * 重点验证四件事：
 *  1. 输出里**只有白名单字段**，没有任何 HTML 片段；
 *  2. display:none / visibility:hidden / aria-hidden 的节点文字一个字都不带出来；
 *  3. 隐藏表单字段（#workEnc / input[type=hidden]）与 Cookie 完全没被读取；
 *  4. 脚本对页面只读——执行前后 DOM 完全一致。
 */
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const scriptPath = path.resolve(__dirname, '..', 'assets', 'js', 'page_reader.js');
const source = fs.readFileSync(scriptPath, 'utf8');

let failed = 0;

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${name}`);
  if (!ok) {
    console.log(`        期望: ${JSON.stringify(expected)}`);
    console.log(`        实际: ${JSON.stringify(actual)}`);
  }
}

function checkTrue(name, condition, detail) {
  if (!condition) failed++;
  console.log(`${condition ? '  PASS' : '  FAIL'}  ${name}`);
  if (!condition && detail) console.log(`        ${detail}`);
}

/** 在给定 HTML 里跑一遍脚本，返回 tasks() / courses() 与只读指纹 */
function run(body) {
  const dom = new JSDOM(`<!DOCTYPE html><body>${body}</body>`, {
    url: 'https://mooc1.chaoxing.com/mooc2/work/list?courseId=1&classId=2&enc=SECRET-ENC',
    runScripts: 'outside-only',
  });

  const before = dom.window.document.documentElement.outerHTML;
  dom.window.eval(source);
  const after = dom.window.document.documentElement.outerHTML;

  const reader = dom.window.__cxPageReader;
  return {
    tasks: reader.tasks(),
    courses: reader.courses(),
    domUnchanged: before === after,
  };
}

const TASKS_HTML = `
<ul class="ulDiv">
  <li onclick="goTask(this);"
      data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=10000200&answerId=2&enc=SECRET-ENC"
      data-workid="10000200">
    <div class="tag work-icon icon-zy"></div>
    <div class="right-content">
      <p class="overHidden2 fl">作业20260926</p>
      <p class="status fl">未交</p>
      <p style="display:none">隐藏的教师备注：张三 学号20230001</p>
      <p aria-hidden="true">aria 隐藏文字</p>
      <input type="hidden" name="workEnc" value="SECRET-WORK-ENC">
      <script>var secret = 'SCRIPT-SECRET';</script>
    </div>
  </li>
  <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=2">
    <p class="overHidden2 fl" aria-hidden="true">不该出现的隐藏标题</p>
    <p class="status fl" style="visibility:hidden">已交</p>
    <p class="overHidden2 fl">作业B</p>
    <p class="time">截止时间：2026-11-01 23:59</p>
  </li>
  <li data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&examId=9" data-examid="9">
    <p class="overHidden2 fl">期中测验</p>
  </li>
  <li style="display:none" data="https://mooc1.chaoxing.com/mooc-ans/mooc2/work/task?courseId=1&workId=4">
    <p class="overHidden2 fl">整行隐藏的作业</p>
    <p class="status fl">未交</p>
  </li>
</ul>`;

console.log('— 作业行：只输出白名单字段 —');
{
  const { tasks, domUnchanged } = run(TASKS_HTML);
  const rows = tasks.rows;

  check('整行隐藏的作业被跳过（3 行）', rows.length, 3);
  check('字段集合固定', Object.keys(rows[0]).sort(), [
    'deadline',
    'examId',
    'status',
    'title',
    'url',
    'workId',
  ]);
  check('标题只取可见文字', rows[0].title, '作业20260926');
  check('状态取自可见节点', rows[0].status, '未交');
  check('workId 来自 data 属性', rows[0].workId, '10000200');
  check('隐藏域不受影响：URL 原样（含必要参数）', rows[0].url.includes('workId=10000200'), true);

  const serialized = JSON.stringify(tasks);
  checkTrue('输出里没有任何 HTML 标签', serialized.indexOf('<') === -1, serialized.slice(0, 120));
  checkTrue('隐藏备注没有泄漏', serialized.indexOf('学号20230001') === -1);
  checkTrue('aria-hidden 文字没有泄漏', serialized.indexOf('aria 隐藏文字') === -1);
  checkTrue('隐藏表单字段没有泄漏', serialized.indexOf('SECRET-WORK-ENC') === -1);
  checkTrue('script 内容没有泄漏', serialized.indexOf('SCRIPT-SECRET') === -1);
  checkTrue('地址参数里的 enc 未出现在 envelope 顶层的 host 字段', tasks.host === 'mooc1.chaoxing.com', tasks.host);

  check('第二行：隐藏标题被跳过，取到可见的作业B', rows[1].title, '作业B');
  check('第二行：visibility:hidden 的状态不算', rows[1].status, '');
  check('第二行：日期只给匹配到的那一小段', rows[1].deadline, '2026-11-01 23:59');
  checkTrue('第二行：无状态时才带截断行文本', typeof rows[1].text === 'string');
  checkTrue('第二行：截断行文本不含隐藏的「已交」', rows[1].text.indexOf('已交') === -1, rows[1].text);
  check('第三行：考试 id 走 examId 字段', rows[2].examId, '9');
  check('第三行：没有状态节点就不编造状态', rows[2].status, '');
  checkTrue('只读：执行前后 DOM 完全一致', domUnchanged);
}

console.log('— 课程卡片：只输出课程名 + 链接 —');
{
  const { courses, domUnchanged } = run(`
    <div class="course-list">
      <a class="color1" href="https://mooc1.chaoxing.com/visit/stucoursemiddle?courseid=100008001&clazzid=100007001&cpi=100009001" target="_blank">
        <span class="course-name overHidden2" title="英语四六级">英语四六级</span>
        <i class="icon-news"></i>
      </a>
      <li onclick="location.href='/visit/stucoursemiddle?courseid=77&clazzid=88&cpi=99'">
        <div class="course-name">大学英语</div>
      </li>
      <a class="color1" href="javascript:void(0);"><span class="course-name">无链接课程</span></a>
      <a class="color1" href="/visit/stucoursemiddle?courseid=5&clazzid=6" style="display:none">
        <span class="course-name">隐藏课程</span>
      </a>
    </div>`);

  const rows = courses.rows;
  check('只留真有 courseid 的可见卡片（隐藏的、javascript: 的都丢掉）', rows.length, 2);
  check('字段只有 name / href', Object.keys(rows[0]).sort(), ['href', 'name']);
  check('课程名取可见文字', rows[0].name, '英语四六级');
  check('链接原样带回，交给 Dart 拆参数', rows[0].href.includes('courseid=100008001'), true);
  check('onclick 里的地址也能取到', rows[1].href, '/visit/stucoursemiddle?courseid=77&clazzid=88&cpi=99');
  checkTrue(
    '隐藏卡片与 javascript: 卡片都没进来',
    JSON.stringify(rows).indexOf('隐藏课程') === -1 &&
      JSON.stringify(rows).indexOf('无链接课程') === -1
  );
  check('课程名提示来自 .course-name', courses.courseName, '英语四六级');
  checkTrue('只读：执行前后 DOM 完全一致', domUnchanged);
  const serialized = JSON.stringify(courses);
  checkTrue('输出里没有任何 HTML 标签', serialized.indexOf('<') === -1, serialized.slice(0, 120));
}

console.log('— 空页面不抛异常 —');
{
  const { tasks, courses } = run('');
  check('tasks 空数组', tasks.rows, []);
  check('courses 空数组', courses.rows, []);
}

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
