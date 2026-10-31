# Chaoxing Helper（AI 阅读辅助器）

> **本项目仅供 Flutter + WebView 技术学习与交流，不包含任何自动点击与绕过风控功能。**

一个用 Flutter 写的「网页阅读 + AI 辅助理解」实验项目：在内置 WebView 里打开学习通页面，
读取当前页的**题干文字**，交给用户自己配置的大模型给出**参考答案**，用户对照答案自行作答。

---

## 能力边界（请先读这段）

**会做的事**

- 用 `InAppWebView` 打开网页，正常浏览、前进后退
- 读取**当前页面的题干与选项文字**（纯读取，不修改 DOM）
- **按大题分条**：一页里有几道独立大题就出几条，同一道大题下的多个空只算一条
  （靠真题干 + 父子关系判断，不会把「简答题（10分）」这种类型标签当成题干）
- 把文字发给用户自己配置的 OpenAI 兼容模型（DeepSeek / Kimi / 豆包 / 任意中转站）
- 以**非模态悬浮面板**展示参考答案，供用户**自己对照页面手动作答**
  面板可拖拽调高度、可最小化成小球、答案可一键复制；
  顶部是**题号按钮栏**（`[1] [2] [3] …`，Wrap 自动换行），点哪个题号，
  下方的卡片就只显示那一题的答案（带复制），像遥控器一样逐题对照
- 从作业列表页导入作业条目，在本地做一个待办看板
  （**只统计「未交/待交」**；每次提取成功都用网页最新结果**整批覆盖**该课程的旧缓存，
  不与旧状态合并，避免脏数据越堆越多）
- 每次运行前后采集**页面指纹**并打到日志里，可自行核对网页未被改动

**不会做的事**

- ❌ 不会点击任何选项 / 按钮（源码里没有任何 `.click()`）
- ❌ 不会向网页写入内容（不碰 `innerHTML`、不给 `input.value` 赋值、不触发事件）
- ❌ 不会自动提交、不会点「保存」
- ❌ 没有指纹伪装、没有 `navigator.webdriver` 抹除、不绕过任何风控或验证码
- ❌ 不内置任何账号、Cookie 或题库
- ❌ 不做任何后台自动扫描（无定时器、无静默请求、无自动翻页）

**App 在 WebView 里执行的全部 JS 只有 3 段，均为只读**

| 脚本 | 作用 |
| --- | --- |
| `assets/js/extractor.js` | 读取题干/选项文字，回传给 Flutter |
| 页面快照上报脚本 | 读取 `documentElement.outerHTML` 回传，用于导入作业列表 |
| DOM 探测脚本 | 统计 `.TiMu` 节点数量并返回布尔值，用于按钮可用性提示 |

三者都只有 `querySelectorAll` / `outerHTML` / 读取文本，**没有任何写操作**。

**已知限制**

- 题目提取只读**顶层文档**，题目在 iframe 内的页面会提取不到（这是刻意做的简化）
- 只读取文字，**不处理图片**：纯图片题无法分析
- 学习通**没有**「全部课程待办聚合页」，作业只能一门一门进，本工具不做自动遍历

---

## 关于「一键提取全部课程作业」

先说结论：**做不到一次性拿到所有课的作业**。原因如下（实测 + 开源项目交叉验证）：

| 候选全局页 | 实测结果 |
| --- | --- |
| `https://mooc1.chaoxing.com/visit/interaction` | 登录后只是一个**课程列表外壳**：`<ul id="fileList">` 为空，课程卡片由 AJAX `/visit/courselistdata` 异步填充；页面上没有任何作业条目 |
| `/mooc-ans/visit/notice`、`/notice/all` | 404 |
| `/mooc-ans/visit/taskcourses`、`/todolist`、`/getallwork` | 404 |

主流开源项目（chaoxing-mcp 的 `xt_homework_all`、xuexitong-cli 的 `work list --all`、
SuperStarInfoFetch 的 `a_get_course_info_of_type('works')`）实现「全部课程作业」时，
走的都是**逐课程循环 + 每门课单独的 `enc` / `stuenc` 参数**——
这两个参数不出现在任何页面源码里，必须逐门课从 URL 上抓下来。

所以本项目改为 **课程快捷入口** 方案：不追求一步到位拿全部作业，
但把「在网页里翻找课程」这一步彻底省掉。

**怎么用**

1. 主页切到「**入口**」页 → 点「导入课程」
2. 自动打开学习通课程列表页 → 等课程卡片显示出来 → 点右上角 **📖 保存全部课程**
   （这一步纯读 DOM，不点击卡片、不跳转、不改页面）
3. 回到主页，每门课就是一张卡片。点卡片 → WebView **直接跳到该课程页面**
4. 之后在这门课里点右上角 🗒 **提取本页作业**，会把这次的页面地址（带 `enc`）记下来；
   下次点同一张卡片，卡片会显示「**直达作业列表**」，一步到位

卡片长按可以移除。整套流程依然由用户自己点、自己看、自己手动作答。

---

## 使用须知

1. **本项目与超星 / 学习通官方无任何关联**，未获得其授权或认可。
2. 使用本项目可能违反你所处学校/机构的学术规范与平台用户协议，**风险由使用者自行承担**。
   本项目不鼓励、也不为「代做作业 / 考试作弊」等行为提供支持。
3. 请勿用于任何考试、测验、限时测评等场景。
4. API Key 以明文保存在本机 `SharedPreferences`，请勿在公用设备上填写。
5. 代码以学习为目的开源，**不提供任何可用性保证**，也不承诺适配平台后续改版。

---

## 快速开始

```bash
flutter pub get
flutter run                 # 调试
flutter build apk --release # 打包

cd tool && npm install      # 一次性，用于跑提取脚本的回归测试
node tool/test_extractor.js
```

首次启动：点右上角 ⚙️ → 添加模型（名称 / BaseUrl / Model / API Key）→ 保存。
BaseUrl 支持只填到 `/v1`，会自动补 `/chat/completions`。

## 目录结构

```
lib/
  core/config/app_config.dart            模型列表配置（本地持久化）
  core/network/cookie_sync_helper.dart   登录态与 Cookie
  data/services/ai_solver_service.dart   多模型顺序重试的 AI 调用
  data/services/scanner_service.dart     HTML 解析（作业 / 课程列表）
  data/services/task_store.dart          作业列表本地缓存
  data/services/course_store.dart        课程快捷入口本地缓存
  ui/pages/dashboard_page.dart           看板 + 课程入口 + 模型设置
  ui/pages/work_webview_page.dart        WebView 阅读页 + 悬浮面板 + 课程导入
  ui/widgets/answer_float_panel.dart     可拖拽/最小化/一键复制的悬浮答案面板
assets/js/extractor.js                   题干文字提取（只读，含去重）
tool/test_extractor.js                   提取脚本的 Node 回归测试
```

## 免责声明

本项目按「现状」提供，不附带任何明示或暗示的担保。作者不对因使用本项目产生的
任何直接或间接损失负责，包括但不限于账号处罚、成绩认定、数据丢失等。
如果你不同意上述任何一条，请立即停止使用并删除本项目。
