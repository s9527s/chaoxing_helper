/**
 * 极简题目提取脚本（只读，不修改页面）
 *
 * 设计原则：
 *  1. 只读取顶层文档里的题干与选项文字，**不穿透 iframe**；
 *  2. **不处理图片**（不做 base64、不下载资源）；
 *  3. **不点击任何元素、不写入任何 DOM**，纯读取后回传。
 *
 * 输出的 payload 结构与 Flutter 侧 handleQuestionsExtracted 约定一致：
 *   { totalCount, solvableCount, blockCount, questions: [{index,type,stem,stemImages,options}] }
 */
(function () {
    'use strict';

    /** 取元素可见文本并压缩空白 */
    function textOf(el) {
        if (!el) return '';
        var raw = el.innerText || el.textContent || '';
        return String(raw).replace(/\s+/g, ' ').trim();
    }

    /** 依据题干关键字与控件类型判断题型 */
    function detectType(stem, block) {
        if (stem.indexOf('多选') !== -1) return 'multiple';
        if (stem.indexOf('判断') !== -1) return 'judge';
        if (stem.indexOf('填空') !== -1) return 'fill';
        if (stem.indexOf('简答') !== -1) return 'fill';
        if (block.querySelector('input[type="checkbox"]')) return 'multiple';
        if (block.querySelector('textarea, input[type="text"]')) return 'fill';
        return 'single';
    }

    /** 读取选项文字（只保留 label + text，不含任何图片处理） */
    function readOptions(block) {
        var options = [];
        var els = block.querySelectorAll('.Zy_ulTop li, .stem_answer .answer_p, .qtDetail li');
        for (var i = 0; i < els.length; i++) {
            var text = textOf(els[i]);
            if (!text) continue;
            options.push({
                label: String.fromCharCode(65 + options.length),
                text: text
            });
        }
        return options;
    }

    var blocks = document.querySelectorAll('.TiMu, .questionLi');
    var questions = [];

    for (var i = 0; i < blocks.length; i++) {
        var block = blocks[i];
        var titleEl = block.querySelector('.Zy_TItle, .mark_name, .qtTitle') || block;
        var stem = textOf(titleEl);

        // 没有文字的块（纯图片题、纯材料块）直接跳过
        if (!stem) continue;

        questions.push({
            index: questions.length + 1,
            type: detectType(stem, block),
            stem: stem,
            options: readOptions(block)
        });
    }

    var payload = {
        totalCount: questions.length,
        solvableCount: questions.length,
        blockCount: blocks.length,
        questions: questions
    };

    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('onQuestionsExtracted', payload);
    }
})();
