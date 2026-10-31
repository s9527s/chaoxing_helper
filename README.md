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
  毛玻璃面板可拖拽调高度、可最小化成小球、答案可一键复制；
  顶部是**横向滚动的题号胶囊**（`[1] [2] [3] …`），点哪个题号，
  下方的卡片就只显示那一题的答案（带复制），像遥控器一样逐题对照
- 运行日志默认收在标题栏的**状态胶囊**里（绿点「已就绪」/ 转圈「分析中」），点一下才展开
- 界面统一走 Material 3 设计 token（`ui/theme/app_theme.dart`）：`#4F46E5` 主色、
  `#F8FAFC` 页面底色、16 圆角细边框卡片、无阴影
- 从作业列表页导入作业条目，在本地做一个待办看板
  （**只统计「未交/待交」**；每次提取成功都用网页最新结果**整批覆盖**该课程的旧缓存，
  不与旧状态合并，避免脏数据越堆越多）
- **侧滑删除**：网页上把作业交了，回到看板把这行往左一划，卡片立刻消失并写回本地缓存，
  留一个 5 秒的「撤销」；杀进程重进也不会再冒出来
- **顶部刷新（本次真正修好）**：点一下，只针对**看板上已有的那几门课**，用已登录 Cookie
  各发一次只读 GET，重新拉一遍作业列表；某门课未交数变 0 就自动从看板移除，
  有变化就更新。取不到（登录态失效 / 页面缺权限）时**保留旧数据**，绝不用空结果清库
- **已交作业拦截**：点「提取作业 / 开始分析」前先只读判断一次，这份作业已经交了就直接弹窗
  「当前作业已完成，无需提取」，不再发起 AI 请求、不浪费额度
- 每次运行前后采集**页面指纹**并打到日志里，可自行核对网页未被改动

**不会做的事**

- ❌ 不会点击任何选项 / 按钮（源码里没有任何 `.click()`）
- ❌ 不会向网页写入内容（不碰 `innerHTML`、不给 `input.value` 赋值、不触发事件）
- ❌ 不会自动提交、不会点「保存」
- ❌ 没有指纹伪装、没有 `navigator.webdriver` 抹除、不绕过任何风控或验证码
- ❌ 不内置任何账号、Cookie 或题库
- ❌ 不做任何后台自动扫描（无定时器、无静默请求、无自动翻页）

**App 在 WebView 里执行的全部 JS 只有 5 段，均为只读**

| 脚本 | 作用 |
| --- | --- |
| `assets/js/extractor.js` | 读取题干/选项文字，回传给 Flutter |
| 页面快照上报脚本 | 读取 `documentElement.outerHTML` 回传，用于导入作业列表 |
| DOM 探测脚本 | 统计 `.TiMu` 节点数量并返回布尔值，用于按钮可用性提示 |
| 提交状态探测脚本 | 数一数可编辑控件、看看有没有「我的答案 / 正确答案」文字，判断是否已交 |
| 页面指纹脚本 | 读取 `outerHTML.length` 与几个节点特征，用于前后比对 |

五者都只有 `querySelectorAll` / `outerHTML` / 读取文本，**没有任何写操作**。

**关于「刷新」这一次网络请求（写清楚，避免误解）**

刷新按钮点下去时，App 会用本机已登录的 Cookie 对**看板上已有的课程**各发一次 `GET`：

1. 先取课程页（`mooc2-ans/mycourse/stu`），从隐藏域 `#workEnc`、`#enc`、`#t` 里读出参数；
2. 再用这些参数拼出作业列表地址 `/mooc2/work/list` 并读取；
3. 解析出「未交」条目后覆盖该课程的旧缓存。

它的边界是刻意收紧的：**只由用户点击触发**（进程里没有任何定时器 / 后台轮询）、
**只请求看板里那几门课**（不做全量课程遍历、不猜 URL）、并发上限 3、**只 GET 不提交**。

**启动阶段不联网**

冷启动只做**本地**判断（Cookie 里 `uid` / `_d` / `vc3` 是否齐全），不发任何请求。
登录态真失效时：点刷新会收到「登录态已失效，请重新登录」，打开课程页也会被跳转到登录页，
两条路径都能兜住，因此不需要在启动时先向服务器探一次。

**三条红线的自动化守卫**

`test/readonly_guard_test.dart` 扫描源码本身，把红线和测试绑在一起：

| 守卫 | 判定 |
| --- | --- |
| 绝对只读 | `lib/` 与 `assets/` 里出现 `click` / `dispatchEvent` / `innerHTML=` / `value=` / `setAttribute` / `appendChild` 等 DOM 写操作 → 测试失败 |
| 无静默请求 | `core/network` 与 `data/services` 里出现 `Timer` / `Future.delayed` → 测试失败；启动页出现 `DioClient` → 测试失败 |
| 无内置凭据 | 源码里出现 `sk-` 开头的长串密钥、仓库里出现 `key.properties` / `.jks` → 测试失败 |

唯一豁免是 `extractor.js` 里对 **clone 副本** 的 `removeChild`（真实页面不受影响），
该行带 `readonly-audit-ok` 标记，且全仓库只允许存在 1 处。

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
走的都是**逐课程循环**：每门课都得先打开一次课程页，才能拿到属于它的
`enc` / `stuenc` / `workEnc`。

> 这几个参数到底从哪来（2026-10 实机确认）：它们就在**课程页的隐藏域**里——
> `<input id="enc">`、`<input id="workEnc">`、`<input id="t">`。
> 作业页签点下去时，前端 JS（`course-stu.js`）把 `courseId + classId + cpi + ut=s + t +
> stuenc=#enc + enc=#workEnc` 拼成 `/mooc2/work/list?...`；**少了 `enc` 服务端只回一句
> 「无权限的操作！」**。所以「刷新」是「先取课程页 → 读隐藏域 → 再取作业列表」两步。

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

**界面细节**

- 统计卡：渐变底 + 极淡的流光扫过（3.4s 一轮，`IgnorePointer` 不吃点击）；
  数字 32sp 且用 `FontFeature.tabularFigures()` 等宽，倒计时跳动时不会左右晃
- 列表：卡片之间 12dp 间距、卡片内 16dp padding；进入时按序淡入上移（`_Entrance`），
  删除 / 切换视图走 240–260ms 的 `AnimatedSwitcher`，不再是生硬闪现
- 悬浮答案面板：28dp 圆角 + 极淡高斯模糊（`BackdropFilter`），
  题号胶囊与复制按钮按下有 0.92 缩放的按压反馈
- 侧滑：向左滑动卡片，右侧滑出红色「✓ 交了，移除」底衬，滑过 32% 即触发删除

---

## 使用须知

1. **本项目与超星 / 学习通官方无任何关联**，未获得其授权或认可。
2. 使用本项目可能违反你所处学校/机构的学术规范与平台用户协议，**风险由使用者自行承担**。
   本项目不鼓励、也不为「代做作业 / 考试作弊」等行为提供支持。
3. 请勿用于任何考试、测验、限时测评等场景。
4. **API Key 和登录 Cookie 均以明文保存在本机 `SharedPreferences`**，未做加密。
   请勿在公用 / root 过的设备上填写，也不要随意备份该应用的 `shared_prefs` 目录。
   网络请求一律走 HTTPS（`android:usesCleartextTraffic="false"`），手填 `http://` 的模型地址会直接失败。
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
  data/services/task_refresh_service.dart 刷新取数（只读 GET + 结果合并，纯函数可单测）
  data/services/submission_detector.dart  是否「已交」的判定规则（纯函数）
  data/services/task_store.dart          作业列表本地缓存
  data/services/course_store.dart        课程快捷入口本地缓存
  ui/theme/app_theme.dart                全局设计 token（配色 / 圆角 / ThemeData）
  ui/pages/dashboard_page.dart           看板 + 课程入口 + 模型设置（含侧滑删除 / 刷新 / 动效）
  ui/pages/work_webview_page.dart        WebView 阅读页 + 悬浮面板 + 课程导入 + 已交拦截
  ui/widgets/answer_float_panel.dart     可拖拽/最小化/一键复制的悬浮答案面板
assets/js/extractor.js                   题干文字提取（只读，含去重）
test/                                    单测（解析 / 刷新合并 / 已交判据 / 看板交互）
tool/test_extractor.js                   提取脚本的 Node 回归测试
```

## 免责声明

本项目按「现状」提供，不附带任何明示或暗示的担保。作者不对因使用本项目产生的
任何直接或间接损失负责，包括但不限于账号处罚、成绩认定、数据丢失等。
如果你不同意上述任何一条，请立即停止使用并删除本项目。
