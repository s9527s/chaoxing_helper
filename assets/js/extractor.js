/**
 * 题目提取脚本（严格只读）
 *
 * 设计原则：
 *  1. 只读取顶层文档里的题干与选项**可见文字**，**不穿透 iframe**；
 *  2. **不处理图片**（不做 base64、不下载资源）；
 *  3. **不点击任何元素、不写入任何 DOM**——不设属性、不改 innerHTML、
 *     不给 input.value 赋值、不触发任何事件、不 clone 节点；
 *  4. **不读隐藏内容**：display:none / visibility:hidden / opacity:0 / hidden /
 *     aria-hidden="true" / script|style 里的文字一律跳过；
 *  5. 不回传任何 HTML：只把题干、选项等文字整理成 JSON。
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
        if (!el || !isVisible(el)) return '';
        if (typeof el.innerText === 'string' && el.innerText.trim() !== '') {
            return String(el.innerText).replace(/\s+/g, ' ').trim();
        }
        return walkVisibleText(el, '');
    }

    /** 这个元素自己是否属于「看不见 / 不该取文字」的节点 */
    function isHidden(el) {
        if (!el || el.nodeType !== 1) return false;

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

    /** 自身及所有祖先都可见才算可见 */
    function isVisible(el) {
        var node = el;
        while (node && node.nodeType === 1) {
            if (isHidden(node)) return false;
            node = node.parentElement;
        }
        return true;
    }

    /**
     * 遍历文本节点拼文字，跳过隐藏节点与指定子树。
     *
     * **只看不改**：不 clone、不删节点，页面结构与文字都不动。
     * [dropSelector] 用于把选项区 / 答案解析区这类「不是题干」的子树排除掉。
     */
    function walkVisibleText(el, dropSelector) {
        if (!el || !el.ownerDocument) return '';

        var out = '';
        try {
            // 4 === NodeFilter.SHOW_TEXT，用数字避免依赖全局 NodeFilter
            var walker = el.ownerDocument.createTreeWalker(el, 4, null);
            var node = walker.nextNode();
            var lastParent = null;
            var lastOk = false;

            while (node) {
                var parent = node.parentElement;
                if (parent) {
                    if (parent !== lastParent) {
                        lastParent = parent;
                        lastOk = isVisible(parent) &&
                            !(dropSelector && parent.closest && parent.closest(dropSelector));
                    }
                    if (lastOk) out += ' ' + node.nodeValue;
                }
                node = walker.nextNode();
            }
        } catch (e) {
            return '';
        }

        return String(out).replace(/\s+/g, ' ').trim();
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
     *
     * 这里逐文本节点读取，并跳过选项区 / 答案解析区 / 隐藏节点，
     * 全程**不 clone、不删节点**，页面一个字节都不会被改动。
     */
    function fallbackStem(block) {
        var text = walkVisibleText(
            block,
            'script, style, .Zy_ulTop, .mark_name, .answerSheet, .bottomList'
        );
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

    /** 题干开头 40 字：题型只在开头判断，避免正文里出现「多选」就被带偏 */
    function headOf(block) {
        for (var s = 0; s < TITLE_SELECTORS.length; s++) {
            var els = toArray(block.querySelectorAll(TITLE_SELECTORS[s]));
            for (var i = 0; i < els.length; i++) {
                var text = textOf(els[i]);
                if (text) return text.slice(0, 40);
            }
        }
        return textOf(block).slice(0, 40);
    }

    /** 题干前缀 → 题型（顺序有意义：多选/判断要先于泛化的单选词） */
    var HEAD_TYPE_RULES = [
        {
            type: 'multiple',
            re: /^(?:[一二三四五六七八九十]+[、.．)）]|\d+[、.．)）])?\s*(?:多项选择|多选|不定项)/
        },
        {
            type: 'judge',
            re: /^(?:[一二三四五六七八九十]+[、.．)）]|\d+[、.．)）])?\s*判断/
        },
        {
            type: 'fill',
            re: /^(?:[一二三四五六七八九十]+[、.．)）]|\d+[、.．)）])?\s*(?:填空|简答|问答|名词解释|论述|计算|分析|翻译|写作|作文|材料|综合)/
        },
        {
            type: 'single',
            re: /^(?:[一二三四五六七八九十]+[、.．)）]|\d+[、.．)）])?\s*(?:单项选择|单选)/
        }
    ];

    /**
     * 题型判定：**先看控件，再看题干前缀**。
     *
     * 旧实现用全文 indexOf 找「多选 / 判断」，只要正文或选项里出现这两个词
     * 就会把整道题带偏（比如单选题的选项文本里写了「多选」）。
     * 现在按可信度从高到低：
     *  1. `input[type=checkbox]` → 多选（学习通多选就是 checkbox，最可靠）
     *  2. 题干前缀命中「判断」 → 判断（判断题用的也是 radio，只能靠前缀区分）
     *  3. 题干前缀命中其他题型 → 对应类型
     *  4. 只有 radio 且无前缀 → 单选
     *  5. 有作答区（含富文本编辑器）→ 填空/简答
     */
    function detectType(block) {
        if (block.querySelector('input[type="checkbox"]')) return 'multiple';

        var head = headOf(block);
        for (var r = 0; r < HEAD_TYPE_RULES.length; r++) {
            if (HEAD_TYPE_RULES[r].re.test(head)) return HEAD_TYPE_RULES[r].type;
        }

        if (block.querySelector('input[type="radio"]')) return 'single';
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

    // 只在主框架上报：本脚本若被注入到子框架，不允许往 Flutter 抛任何数据。
    // （插件本身也只往主框架注入，这里是第二道闸，防止将来用法变化。）
    if (window.top !== window.self) return;

    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('onQuestionsExtracted', payload);
    }
})();
