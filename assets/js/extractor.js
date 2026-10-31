/**
 * 题目提取脚本（严格只读）
 *
 * 设计原则：
 *  1. 只读取顶层文档里的题干与选项文字，**不穿透 iframe**；
 *  2. **不处理图片**（不做 base64、不下载资源）；
 *  3. **不点击任何元素、不写入任何 DOM**——不设属性、不改 innerHTML、
 *     不给 input.value 赋值、不触发任何事件。
 *     （fallbackStem 里的 cloneNode 只造一个脱离文档的副本用于取文字，
 *       不会碰页面本身。）
 *
 * 题目归并规则（关键）：
 *  A. **题干取值要挑真的那个**。学习通有时把「简答题（10分）」这类类型标签
 *     排在真题干前面，若只取第一个命中的节点，两道不同的简答题会拿到一模一样
 *     的题干，随后被当成重复项合并——第二题就消失了。这里按选择器优先级依次找
 *     「非类型标签」的文字，取最长的一条；实在没有才退回块内正文。
 *  B. **只有「同一道题」才折叠**：子块被父块包住、且子块没有自己的独立题干时，
 *     它只是这道题的一个空/一个作答区，折叠掉。
 *  C. **容器不参与出题**：父块里若含「各有独立题干」的子块，父块只是分组标题，
 *     跳过它，让子块各自成题。
 *  D. **兄弟块绝不按题干合并**：只有题干、空数、选项、正文全部一致（真正重复
 *     渲染的同一块）才合并；类型标签这种泛化题干一律不参与合并。
 *
 * 输出的 payload 结构与 Flutter 侧 handleQuestionsExtracted 约定一致：
 *   { totalCount, solvableCount, blockCount, collapsedCount,
 *     questions: [{index,type,stem,options,blankCount}] }
 */
(function () {
    'use strict';

    /** 只表示题型/分值的标签，不能当题干用 */
    var GENERIC_LABEL = new RegExp(
        '^(?:[一二三四五六七八九十]+[、.．)）]|\\d+[、.．)）])?\\s*' +
        '(?:单项选择|多项选择|不定项选择|单选|多选|判断|填空|简答|问答|名词解释|' +
        '论述|计算|分析|翻译|写作|作文|材料|综合|其他)题?\\s*' +
        '[（(]?\\s*(?:\\d+(?:\\.\\d+)?\\s*分)?\\s*[）)]?$'
    );

    /** 题干候选节点，按可信度从高到低 */
    var TITLE_SELECTORS = [
        '.Zy_TItle',
        '.qtContent',
        '.qtTitle',
        '.stem',
        '.subject',
        '.mark_name'
    ];

    /** 取元素可见文本并压缩空白 */
    function textOf(el) {
        if (!el) return '';
        var raw = el.innerText || el.textContent || '';
        return String(raw).replace(/\s+/g, ' ').trim();
    }

    function toArray(nodes) {
        return Array.prototype.slice.call(nodes || []);
    }

    /** 是否只是「简答题（10分）」这种类型标签 */
    function isGeneric(text) {
        if (!text) return true;
        var t = String(text).replace(/\s+/g, '').replace(/[：:]$/, '');
        return GENERIC_LABEL.test(t);
    }

    /** el 是否被 list 中任意一个元素包含（且不是它自己） */
    function isInside(el, list) {
        for (var i = 0; i < list.length; i++) {
            if (list[i] !== el && list[i].contains(el)) return true;
        }
        return false;
    }

    /** DOM 层级深度，用来保证「先处理外层」 */
    function depthOf(el) {
        var d = 0;
        var node = el;
        while (node.parentElement) {
            d++;
            node = node.parentElement;
        }
        return d;
    }

    function descendantsOf(el, list) {
        var out = [];
        for (var i = 0; i < list.length; i++) {
            if (list[i] !== el && el.contains(list[i])) out.push(list[i]);
        }
        return out;
    }

    /**
     * 找到这个块「自己的」题干。
     * 跳过被更内层题目块包住的节点，否则父块会抢走子块的题干。
     */
    function titleStem(block, inner) {
        for (var s = 0; s < TITLE_SELECTORS.length; s++) {
            var els = toArray(block.querySelectorAll(TITLE_SELECTORS[s]));
            var best = '';
            for (var i = 0; i < els.length; i++) {
                if (els[i] === block) continue;
                if (isInside(els[i], inner)) continue;
                var text = textOf(els[i]);
                if (!text || isGeneric(text)) continue;
                if (text.length > best.length) best = text;
            }
            if (best) return best;
        }
        return '';
    }

    /**
     * 只有类型标签时（简答/作文很常见）用块内正文兜底，
     * 否则两道题会拿到同一个「作文题（20分）」，AI 根本分不清。
     * 这里操作的是一份脱离文档的副本，不会改动页面。
     */
    function fallbackStem(block) {
        var clone = block.cloneNode(true);
        var drop = clone.querySelectorAll(
            'script, style, .Zy_ulTop, .mark_name, .answerSheet, .bottomList'
        );
        for (var i = 0; i < drop.length; i++) {
            // 只删 clone 副本里的节点，真实页面不受影响
            if (drop[i].parentNode) drop[i].parentNode.removeChild(drop[i]); // readonly-audit-ok: clone 副本
        }
        var text = textOf(clone);
        // 去掉残留的类型标签前缀，如「简答题（10分）」
        text = text.replace(
            /^(?:[一二三四五六七八九十]+[、.．)）]|\d+[、.．)）])?\s*[\u4e00-\u9fa5]{2,6}题?\s*[（(][^）)]{0,12}[）)]\s*/,
            ''
        );
        return text.slice(0, 280);
    }

    /** 有没有作答控件（含富文本编辑器） */
    function hasAnswerArea(el) {
        if (el.querySelector(
            'input[type="text"], textarea, [contenteditable="true"], [contenteditable=""]'
        )) {
            return true;
        }
        return !!el.querySelector('.edui-body, .edui-editor, iframe[id^="ueditor"]');
    }

    function detectType(block) {
        var text = textOf(block);
        if (text.indexOf('多选') !== -1 || text.indexOf('多项选择') !== -1) return 'multiple';
        if (text.indexOf('判断') !== -1) return 'judge';
        if (text.indexOf('填空') !== -1) return 'fill';
        if (text.indexOf('简答') !== -1 || text.indexOf('问答') !== -1) return 'fill';
        if (text.indexOf('名词解释') !== -1 || text.indexOf('论述') !== -1) return 'fill';
        if (text.indexOf('翻译') !== -1 || text.indexOf('写作') !== -1 || text.indexOf('作文') !== -1) return 'fill';
        if (block.querySelector('input[type="checkbox"]')) return 'multiple';
        if (hasAnswerArea(block)) return 'fill';
        return 'single';
    }

    /** 读取选项文字（去重后按 A/B/C… 重新编号） */
    function readOptions(block) {
        var options = [];
        var seen = {};
        var els = block.querySelectorAll('.Zy_ulTop li, .stem_answer .answer_p, .qtDetail li');
        for (var i = 0; i < els.length; i++) {
            var text = textOf(els[i]);
            if (!text || seen[text]) continue;
            seen[text] = true;
            options.push({
                label: String.fromCharCode(65 + options.length),
                text: text
            });
        }
        return options;
    }

    // ---------- 收集候选块 ----------
    // 必须把 .TiMu 和 .questionLi 全部收进来，哪怕它们是互相嵌套的：
    // 只有拿到完整的父子关系，才知道谁是「一道题」谁是「这道题里的一个空」。
    // 它们也可能是同一个元素（学习通常见 <div class="TiMu questionLi">），
    // querySelectorAll 已按元素去重。
    var candidates = toArray(document.querySelectorAll('.TiMu, .questionLi'));

    // 每个块自己的题干（先算好，后面判断父子关系要用）
    var info = [];
    for (var i = 0; i < candidates.length; i++) {
        var block = candidates[i];
        var inner = descendantsOf(block, candidates);
        var title = titleStem(block, inner);
        info.push({
            el: block,
            inner: inner,
            depth: depthOf(block),
            title: title,
            stem: title || fallbackStem(block)
        });
    }

    var byEl = [];
    for (var i = 0; i < info.length; i++) byEl.push(info[i].el);

    function infoOf(el) {
        for (var i = 0; i < info.length; i++) {
            if (info[i].el === el) return info[i];
        }
        return null;
    }

    // ---------- 判定：容器 / 题目本体 ----------
    var isContainer = [];
    for (var i = 0; i < info.length; i++) {
        var item = info[i];
        var container = false;

        for (var k = 0; k < item.inner.length; k++) {
            var kid = infoOf(item.inner[k]);
            if (!kid) continue;
            // 子块有「自己的标题节点」且和父块不同 → 父块只是分组标题。
            // 这里必须用 kid.title 而不是 kid.stem：只靠正文兜底出来的题干
            // 往往就是选项文字，用它判断会把一个填空大题拆成一堆小题。
            if (kid.title && kid.title !== item.stem && !isGeneric(kid.title)) {
                container = true;
                break;
            }
        }
        // 父块自己没有题干（只有正文兜底），子块却有真题干 → 同样是容器
        if (!container && !item.title) {
            for (var k2 = 0; k2 < item.inner.length; k2++) {
                var kid2 = infoOf(item.inner[k2]);
                if (kid2 && kid2.title) {
                    container = true;
                    break;
                }
            }
        }
        isContainer.push(container);
    }

    // ---------- 收集最终题目：从外到内，被已收题目包住的一律折叠 ----------
    var ordered = info.slice().sort(function (a, b) {
        return a.depth - b.depth;
    });

    var kept = [];
    var collapsedCount = 0;
    for (var i = 0; i < ordered.length; i++) {
        var item = ordered[i];
        if (isContainer[info.indexOf(item)]) {
            collapsedCount++;                          // 分组标题，不算题
            continue;
        }
        if (!item.stem) continue;                      // 纯图片/空块

        var absorbed = false;
        for (var k = 0; k < kept.length; k++) {
            if (kept[k].el !== item.el && kept[k].el.contains(item.el)) {
                absorbed = true;
                break;
            }
        }
        if (absorbed) {
            collapsedCount++;                          // 同一大题里的一个空
            continue;
        }
        kept.push(item);
    }

    // ---------- 去重：只合并真正重复渲染的同一块 ----------
    var questions = [];
    var seenSignature = {};

    for (var i = 0; i < kept.length; i++) {
        var item = kept[i];
        var block = item.el;
        var options = readOptions(block);

        // 类型标签这种泛化题干不具备区分度，绝不拿来合并
        if (!isGeneric(item.stem)) {
            var signature = [
                item.stem,
                textOf(block),
                options.map(function (o) { return o.text; }).join('~'),
                block.querySelectorAll('input[type="text"], textarea').length
            ].join('|');

            if (Object.prototype.hasOwnProperty.call(seenSignature, signature)) {
                collapsedCount++;
                continue;
            }
            seenSignature[signature] = true;
        }

        questions.push({
            index: questions.length + 1,
            type: detectType(block),
            stem: item.stem,
            options: options,
            // 空的个数，供 AI 知道这一题要给出几个空
            blankCount: block.querySelectorAll(
                'input[type="text"], textarea, [contenteditable="true"], [contenteditable=""]'
            ).length
        });
    }

    var payload = {
        totalCount: questions.length,
        solvableCount: questions.length,
        blockCount: kept.length,
        collapsedCount: collapsedCount,
        questions: questions
    };

    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('onQuestionsExtracted', payload);
    }
})();
