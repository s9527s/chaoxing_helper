/**
 * 作业行 / 课程卡片读取脚本（严格只读、结构化、最小化）
 *
 * 与 extractor.js 的分工：
 *  - extractor.js 负责作业详情页的「题干 + 选项」；
 *  - 本文件负责作业列表页的「一行作业」与课程列表页的「一张课程卡片」。
 *
 * 硬约束（改代码前先读一遍）：
 *  1. **绝不把 HTML 交出去**：不使用 outerHTML / innerHTML / cloneNode，
 *     只把需要的几个字段拼成 JSON 返回；
 *  2. **只认可见内容**：跳过 display:none / visibility:hidden / opacity:0 /
 *     hidden / aria-hidden="true" / script|style|noscript|template 里的文字，
 *     页面上看不见的东西一个字都不传；
 *  3. **只读顶层文档**：不遍历 iframe、不读 contentDocument；
 *  4. **不读隐藏域与 Cookie**：不碰 input[type=hidden]、不碰 document.cookie、
 *     不碰 #enc / #workEnc 之类的表单字段；
 *  5. **零写操作**：不点击、不赋值、不改属性、不派发事件。
 *
 * 输出（交给 Flutter 的字段就是这几个，多一个都不要）：
 *   tasks()   → { host, pageTitle, courseName, rows: [
 *                  { title, status, deadline, workId, examId, url, text? } ] }
 *   courses() → { host, pageTitle, courseName, rows: [ { name, href } ] }
 *
 * `text` 只在「页面没有状态节点」时才带，用于判断这行是不是已经结束，
 * 截断到 200 字；其余情况一律不传整行文字。
 */
(function () {
    'use strict';

    var MAX_ROWS = 300;
    var MAX_TITLE = 120;
    var MAX_STATUS = 24;
    var MAX_DEADLINE = 32;
    var MAX_NAME = 60;
    var MAX_URL = 1024;
    var MAX_ROW_TEXT = 200;
    var MAX_COURSE_HINT = 40;

    /** 作业行：与线上 DOM 一致的四种写法 */
    var TASK_ROW_SELECTOR =
        'li[onclick*="goTask"], li[data*="workId"], li[data*="/work/"], li[data*="/exam/"]';

    /** 课程卡片：a.color1 为主，新版退化成带 courseid 的链接 / li[onclick] */
    var COURSE_SELECTOR =
        'a.color1, a[href*="courseid="], a[href*="courseId="], li[onclick*="stucoursemiddle"]';

    var TITLE_SELECTORS = [
        '.overHidden2.fl',
        '.overHidden2',
        '[class*="overHidden"]',
        '.titTxt',
        '.tit',
        '.title'
    ];

    var STATUS_SELECTORS = [
        '.status.fl',
        '.status',
        '[class*="status"]',
        '.zt',
        '.state',
        '[class*="state"]'
    ];

    var NAME_SELECTORS = [
        'span.course-name',
        '.course-name',
        '[class*="course-name"]'
    ];

    /** 行文本兜底时要剔除的噪音片段 */
    var NOISE = {
        '作业': 1, '考试': 1, '任务': 1, '待批阅': 1, '未交': 1, '已交': 1,
        '已完成': 1, '待完成': 1, '进行中': 1, '未开始': 1, '暂无': 1
    };

    var DATE_RE =
        /(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2}))?/;

    /** 压缩空白 + 截断，只留纯文本 */
    function clean(value, max) {
        var text = String(value === null || value === undefined ? '' : value)
            .replace(/\s+/g, ' ')
            .trim();
        if (max && text.length > max) text = text.slice(0, max);
        return text;
    }

    /** 这个元素自己是不是「不可见 / 不需要的文字载体」 */
    function isHiddenNode(el) {
        if (!el || el.nodeType !== 1) return true;

        var tag = String(el.tagName || '').toLowerCase();
        if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'template') {
            return true;
        }
        if (el.hidden === true) return true;
        if (el.getAttribute('aria-hidden') === 'true') return true;

        try {
            var style = window.getComputedStyle ? window.getComputedStyle(el) : null;
            if (style) {
                if (style.display === 'none') return true;
                if (style.visibility === 'hidden' || style.visibility === 'collapse') return true;
                if (style.opacity === '0') return true;
            }
        } catch (e) {}

        return false;
    }

    /** 自身及所有祖先都可见，才算可见 */
    function isVisible(el) {
        var node = el;
        while (node && node.nodeType === 1) {
            if (isHiddenNode(node)) return false;
            node = node.parentElement;
        }
        return true;
    }

    /**
     * 取可见文字。
     *
     * 浏览器里 `innerText` 天然只包含渲染出来的文字（自动排除 display:none、
     * script、style），优先用它；jsdom 等环境没有实现 innerText，就手工遍历
     * 文本节点，并逐个校验祖先可见性——两条路径都不会把隐藏内容带出来。
     */
    function visibleText(el) {
        if (!el || !isVisible(el)) return '';

        if (typeof el.innerText === 'string' && el.innerText.trim() !== '') {
            return clean(el.innerText);
        }

        var out = '';
        try {
            // 4 === NodeFilter.SHOW_TEXT，用数字避免依赖全局 NodeFilter
            var walker = el.ownerDocument.createTreeWalker(el, 4, null);
            var node = walker.nextNode();
            while (node) {
                var parent = node.parentElement;
                if (parent && isVisible(parent)) out += ' ' + node.nodeValue;
                node = walker.nextNode();
            }
        } catch (e) {
            return '';
        }
        return clean(out);
    }

    /** 按选择器顺序找第一个「可见且有文字」的节点 */
    function pickText(root, selectors, max) {
        for (var s = 0; s < selectors.length; s++) {
            var nodes = root.querySelectorAll(selectors[s]);
            for (var i = 0; i < nodes.length; i++) {
                var text = visibleText(nodes[i]);
                if (text) return clean(text, max);
            }
        }
        return '';
    }

    /** 某一行的链接：只认 data 属性，不拼接、不猜地址 */
    function taskUrlOf(row) {
        var url = clean(row.getAttribute('data'), MAX_URL);
        if (url) return url;
        // 少数皮肤把地址放在子节点的 data 上
        var inner = row.querySelector('[data*="/work/"], [data*="workId"], [data*="/exam/"]');
        return inner ? clean(inner.getAttribute('data'), MAX_URL) : '';
    }

    function firstAttr(row, names) {
        for (var i = 0; i < names.length; i++) {
            var value = clean(row.getAttribute(names[i]), 32);
            if (value) return value;
        }
        return '';
    }

    /** 没有状态节点时的标题兜底：从可见行文本里挑第一个不像噪音的片段 */
    function titleFromRowText(rowText) {
        var parts = String(rowText || '').split(' ');
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i].replace(/\s+/g, ' ').trim();
            if (!part) continue;
            if (NOISE[part]) continue;
            if (/^[\d\s:：/.\-]+$/.test(part)) continue;
            return clean(part, MAX_TITLE);
        }
        return '';
    }

    function readTasks() {
        var rows = [];
        var nodes = document.querySelectorAll(TASK_ROW_SELECTOR);

        for (var i = 0; i < nodes.length && rows.length < MAX_ROWS; i++) {
            var row = nodes[i];
            if (!isVisible(row)) continue;

            var url = taskUrlOf(row);
            if (!url) continue;

            var status = pickText(row, STATUS_SELECTORS, MAX_STATUS).replace(/\s+/g, '');
            var rowText = visibleText(row);
            var title = pickText(row, TITLE_SELECTORS, MAX_TITLE);
            if (!title) title = titleFromRowText(rowText);

            var deadlineMatch = DATE_RE.exec(rowText);

            var item = {
                title: title,
                status: status,
                deadline: deadlineMatch ? clean(deadlineMatch[0], MAX_DEADLINE) : '',
                workId: firstAttr(row, ['data-workid', 'data-work-id', 'workid']),
                examId: firstAttr(row, ['data-examid', 'examid']),
                url: url
            };

            // 只有「页面上没有状态节点」时才带上行文字，用于判断是否已结束
            if (!status && rowText) item.text = clean(rowText, MAX_ROW_TEXT);

            rows.push(item);
        }

        return rows;
    }

    /** 课程卡片链接：a 的 href，或 onclick 里引号包住的 courseid 地址 */
    function courseHrefOf(el) {
        var tag = String(el.tagName || '').toLowerCase();
        if (tag === 'a') {
            var href = clean(el.getAttribute('href'), MAX_URL);
            if (href) return href;
        }

        var onclick = el.getAttribute('onclick') || '';
        if (onclick) {
            var match = onclick.match(/['"]([^'"]*courseid=[^'"]*)['"]/i);
            if (match) return clean(match[1], MAX_URL);
        }

        var inner = el.querySelector ? el.querySelector('a[href*="courseid="]') : null;
        return inner ? clean(inner.getAttribute('href'), MAX_URL) : '';
    }

    /** 课程名：节点可见文字 → 节点的 title 属性 → 卡片自身可见文字 */
    function courseNameOf(el) {
        for (var s = 0; s < NAME_SELECTORS.length; s++) {
            var node = el.querySelector(NAME_SELECTORS[s]);
            if (!node) continue;
            var text = visibleText(node);
            if (text) return clean(text, MAX_NAME);
            var title = clean(node.getAttribute('title'), MAX_NAME);
            if (title) return title;
        }

        var ownTitle = clean(el.getAttribute('title'), MAX_NAME);
        if (ownTitle) return ownTitle;

        return clean(visibleText(el), MAX_NAME);
    }

    function readCourses() {
        var rows = [];
        var nodes = document.querySelectorAll(COURSE_SELECTOR);

        for (var i = 0; i < nodes.length && rows.length < MAX_ROWS; i++) {
            var el = nodes[i];
            if (!isVisible(el)) continue;

            var href = courseHrefOf(el);
            if (!href || href.indexOf('courseid=') === -1 && href.indexOf('courseId=') === -1) {
                continue;
            }

            var name = courseNameOf(el);
            if (!name) continue;

            rows.push({ name: name, href: href });
        }

        return rows;
    }

    /** 页面顶部能读到的课程名（学习通课程页有 .course-name 节点） */
    function courseNameHint() {
        var nodes = document.querySelectorAll('[class*="course-name"]');
        for (var i = 0; i < nodes.length; i++) {
            var text = visibleText(nodes[i]);
            if (text) return clean(text, MAX_COURSE_HINT);
        }
        return '';
    }

    function envelope(rows) {
        return {
            // 只给域名：完整地址带 stuenc / courseId，不进 Dart、不进日志
            host: String(location.host || ''),
            pageTitle: clean(document.title, MAX_TITLE),
            courseName: courseNameHint(),
            rows: rows
        };
    }

    window.__cxPageReader = {
        tasks: function () {
            try {
                return envelope(readTasks());
            } catch (e) {
                return envelope([]);
            }
        },
        courses: function () {
            try {
                return envelope(readCourses());
            } catch (e) {
                return envelope([]);
            }
        }
    };
})();
