/**
 * 题目提取脚本（严格只读）
 *
 * 设计原则：
 *  1. 只读取顶层文档里的题干与选项文字，**不穿透 iframe**；
 *  2. **不处理图片**（不做 base64、不下载资源）；
 *  3. **不点击任何元素、不写入任何 DOM**——不设属性、不改 innerHTML、
 *     不给 input.value 赋值、不触发任何事件。
 *
 * 去重规则（本次修复重点）：
 *  A. 只保留最外层的大题块。被别的块包住的子块一律折叠掉，不再单独成题
 *     （学习通把「一个大题 + 若干空」渲染成 .TiMu 里套 .questionLi，
 *      以前两个选择器一起命中，就出现了多个一模一样的题干）；
 *  B. 题干完全相同的块合并成一条，选项取并集；
 *  C. 同一道题内重复的选项文字只保留一个。
 *
 * 输出的 payload 结构与 Flutter 侧 handleQuestionsExtracted 约定一致：
 *   { totalCount, solvableCount, blockCount, collapsedCount,
 *     questions: [{index,type,stem,options,blankCount}] }
 */
(function () {
    'use strict';

    /** 取元素可见文本并压缩空白 */
    function textOf(el) {
        if (!el) return '';
        var raw = el.innerText || el.textContent || '';
        return String(raw).replace(/\s+/g, ' ').trim();
    }

    function toArray(nodes) {
        return Array.prototype.slice.call(nodes || []);
    }

    /** el 是否被 containers 中任意一个元素包含（且不是它自己） */
    function isInside(el, containers) {
        for (var i = 0; i < containers.length; i++) {
            if (containers[i] !== el && containers[i].contains(el)) return true;
        }
        return false;
    }

    /** 只保留最外层块：嵌套在别的块里的一律丢掉 */
    function keepOuterBlocks(nodes) {
        var outer = [];
        for (var i = 0; i < nodes.length; i++) {
            if (!isInside(nodes[i], nodes)) outer.push(nodes[i]);
        }
        return outer;
    }

    function detectType(stem, block) {
        if (stem.indexOf('多选') !== -1) return 'multiple';
        if (stem.indexOf('判断') !== -1) return 'judge';
        if (stem.indexOf('填空') !== -1) return 'fill';
        if (stem.indexOf('简答') !== -1) return 'fill';
        if (block.querySelector('input[type="checkbox"]')) return 'multiple';
        if (block.querySelector('textarea, input[type="text"]')) return 'fill';
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

    /** 把新选项并入已有题目（按文字去重） */
    function mergeOptions(target, incoming) {
        for (var i = 0; i < incoming.length; i++) {
            var duplicated = false;
            for (var j = 0; j < target.length; j++) {
                if (target[j].text === incoming[i].text) {
                    duplicated = true;
                    break;
                }
            }
            if (duplicated) continue;
            target.push({
                label: String.fromCharCode(65 + target.length),
                text: incoming[i].text
            });
        }
    }

    // ---------- 收集大题块 ----------
    var tiMu = toArray(document.querySelectorAll('.TiMu'));
    var candidates = tiMu.slice();

    // 没有被任何 .TiMu 包住的 .questionLi 也单独算一题
    var questionLis = toArray(document.querySelectorAll('.questionLi'));
    for (var i = 0; i < questionLis.length; i++) {
        if (!isInside(questionLis[i], tiMu)) candidates.push(questionLis[i]);
    }

    var blocks = keepOuterBlocks(candidates);

    var questions = [];
    var byStem = {};
    var collapsedCount = 0;

    for (var i = 0; i < blocks.length; i++) {
        var block = blocks[i];

        var titleEl = block.querySelector('.Zy_TItle, .mark_name, .qtTitle');
        var stem = textOf(titleEl);
        if (!stem) {
            var alt = block.querySelector('.qtContent, .stem, .subject');
            stem = textOf(alt);
        }
        // 没有文字的块（纯图片题、纯材料块）直接跳过
        if (!stem) continue;

        // 被折叠掉的子块数量，只用来在日志里说明「合并了多少空」
        collapsedCount += block.querySelectorAll('.TiMu, .questionLi').length;

        var options = readOptions(block);

        var existing = Object.prototype.hasOwnProperty.call(byStem, stem)
            ? byStem[stem]
            : null;

        if (existing) {
            // 同一道大题又出现一次：并入选项，绝不再生成一条新题
            mergeOptions(existing.options, options);
            continue;
        }

        var question = {
            index: questions.length + 1,
            type: detectType(stem, block),
            stem: stem,
            options: options,
            // 填空题里空的数量，供 AI 知道要给出几个答案
            blankCount: block.querySelectorAll('input[type="text"], textarea').length
        };

        byStem[stem] = question;
        questions.push(question);
    }

    var payload = {
        totalCount: questions.length,
        solvableCount: questions.length,
        blockCount: blocks.length,
        collapsedCount: collapsedCount,
        questions: questions
    };

    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('onQuestionsExtracted', payload);
    }
})();
