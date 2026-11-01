# Chaoxing Helper（AI 阅读辅助器）

> **本项目仅供 Flutter + WebView 技术学习与交流，不包含任何自动点击与绕过风控功能。**

> 本项目采用 MIT 协议开源，详见 [LICENSE](LICENSE)。

一个用 Flutter 写的「网页阅读 + AI 辅助理解」实验项目：在内置 WebView 里打开学习通页面，
读取当前页的**题干文字**，交给用户自己配置的大模型给出**参考答案**，用户对照答案自行作答。

---

## 能力边界（请先读这段）

**会做的事**

- 用 `InAppWebView` 打开网页，正常浏览、可返回上一页（**没有「前进」按钮**，代码只实现 `goBack`）
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
- **没有「刷新」按钮（开源版刻意砍掉）**：交了作业就直接侧滑删卡，不需要 App 去请求学习通接口。
  App 代码里对 chaoxing.com **没有任何 HTTP 请求**，所有页面都由用户在可见 WebView 里自己打开
- **已交作业拦截**：点「提取作业 / 开始分析」前先只读判断一次，这份作业已经交了就直接弹窗
  「当前作业已完成，无需提取」，不再发起 AI 请求、不浪费额度
- 每次运行前后采集**页面指纹**并打到日志里，可自行核对网页未被改动

**不会做的事**

- ❌ 不会点击任何选项 / 按钮（源码里没有任何 `.click()`）
- ❌ 不会向网页写入内容（不碰 `innerHTML`、不给 `input.value` 赋值、不触发事件）
- ❌ 不会自动提交、不会点「保存」
- ❌ 未伪装 `navigator.webdriver`、未做 canvas / 字体指纹改写；统一使用桌面 Chrome UA
  以取得桌面版页面，不绕过任何风控或验证码
- ❌ 不内置任何账号、Cookie 或题库
- ❌ 不做任何后台自动扫描（无后台网络轮询；仅有 2 个纯 UI 定时器：倒计时 / DOM 探测）

**页面加载阶段零注入，App 在 WebView 里执行的全部 JS 只有 5 段，均为只读**

| 脚本 | 何时执行 | 作用 |
| --- | --- | --- |
| `assets/js/extractor.js` | 用户点「开始分析」 | 读取题干/选项**文字**，整理成结构化 JSON 回传 |
| `assets/js/page_reader.js` | 用户点「提取作业 / 保存全部」 | 从作业行 / 课程卡片里挑出标题、状态、截止时间文字与链接，整理成结构化 JSON 回传 |
| DOM 探测脚本 | 页面加载后（纯 UI） | 统计 `.TiMu` 节点数量并返回布尔值，只用来点亮按钮 |
| 提交状态探测脚本 | 用户点「提取 / 开始分析」前 | 数可编辑控件、看有没有「我的答案 / 正确答案」，判断是否已交 |
| 页面指纹脚本 | 一次 AI 流水线前后 | 数表单控件个数、控件值总长度、元素节点数，用于前后比对自证 |

**整个链路里没有 `outerHTML` / `innerHTML`**：脚本不把任何 HTML 片段交给 Dart，
只交上面这几个字段。具体边界：

- 只处理**顶层文档**里命中的可见节点，不遍历 iframe（不碰 `contentDocument`）；
- 隐藏内容一律跳过：`display:none` / `visibility:hidden` / `opacity:0` / `hidden` /
  `aria-hidden="true"` / `script|style|noscript` 里的文字都不会被带走；
- 不读 Cookie、不读 `localStorage` / `sessionStorage`、不读 `#enc` / `#workEnc`
  这类隐藏表单字段（`input[type=hidden]` 从不出现在选择器里）；
- 回传字段白名单：作业行只有 `title / status / deadline / workId / examId / url`
  （仅当页面没有状态节点时，额外带一段 ≤200 字的截断行文本用于判断是否已结束），
  课程卡片只有 `name / href`，回执顶层只有 `host / pageTitle / courseName / rows`；
- 只读不写：不点击、不赋值、不改属性、不派发事件。

**关于网络请求（写清楚，避免误解）**

1. **对学习通**：App 自身代码不发任何 HTTP 请求。页面加载全部发生在用户可见的 WebView 里，
   由用户自己点击导航触发；Cookie 通过 `CookieManager` 读取，走的是本地 API。
2. **对大模型**：只有一次 `POST`，发往你自己填的 OpenAI 兼容地址，内容是题干与选项纯文字。
3. 冷启动零联网；进程里没有任何后台轮询（仅有 2 个纯 UI 定时器：倒计时 / DOM 探测）。

**启动阶段不联网**

冷启动只做**本地**判断（Cookie 里 `uid` / `_d` / `vc3` 是否齐全），不发任何请求。
登录态真失效时：打开课程 / 作业页会被跳转到登录页，走一次登录流程即可重新同步 Cookie，
因此不需要在启动时先向服务器探一次。

**三条红线的自动化守卫**

`test/readonly_guard_test.dart` 扫描源码本身，把红线和测试绑在一起：

| 守卫 | 判定 |
| --- | --- |
| 绝对只读 | `lib/` 与 `assets/` 里出现 `click` / `dispatchEvent` / `innerHTML=` / `value=` / `setAttribute` / `appendChild` 等 DOM 写操作 → 测试失败 |
| 无静默请求 | `core/network` 与 `data/services` 里出现 `Timer` / `Future.delayed` → 测试失败；启动页出现 `dio` / `DioClient` → 测试失败 |
| 无内置凭据 | 源码里出现 `sk-` 开头的长串密钥、仓库里出现 `key.properties` / `.jks` → 测试失败 |
| 只交字段 | `lib/` 与 `assets/` 里出现 `outerHTML` / `innerHTML`，或脚本里出现 `document.cookie` / `contentDocument` / `localStorage` → 测试失败 |
| 不解析 HTML | `scanner_service.dart` 里出现 `package:html` / `parseTasksFromHtml` / `parseCourseListHtml` → 测试失败 |

**当前没有任何人工豁免**：仓库里 `readonly-audit-ok` 标记数为 0
（早期版本在 `extractor.js` 里对 clone 副本做过 `removeChild`，现已改为纯文本节点遍历，
`cloneNode` / `removeChild` 都已不存在）。

**已知限制**

- 提取只读**顶层文档里命中的作业行 / 课程卡片节点**；当前提取逻辑不主动遍历或读取 iframe 内容
  （刻意不注入、不跨帧上报），因此 iframe 内的作业列表与题目都可能无法被提取；具体情况尚未完成当前版本实测
  （`assets/js/page_reader.js:14`、`lib/ui/pages/work_webview_page.dart:146-147`）
- 只读取文字，**不处理图片**：纯图片题无法分析（`assets/js/extractor.js:6`「不处理图片，不做 base64，不下载资源」）
- 学习通**没有**「全部课程待办聚合页」，作业只能一门一门进，本工具不做自动遍历

---

## 📱 设备兼容性与功能支持范围

> 本节结论全部来自**代码、构建产物与自动化测试**的静态核查（2026-11 快照）。
> 凡是没做过实机验证的，一律标 ❓，不做推断。

| 标记 | 含义 |
| --- | --- |
| ✅ | 有代码证据（能指到文件与行号） |
| 🧪 | 有自动化测试覆盖且通过（**不等于真机验证**） |
| ⚠️ | 有明确限制 |
| ❓ | 尚未验证 |
| ❌ | 明确不支持 |

### 系统版本

| 项目 | 值 | 证据 |
| --- | --- | --- |
| **最低系统** | **Android 7.0（API 24）** | `android/app/build.gradle.kts:19` → Flutter 默认 `minSdkVersion = 24`；APK 内 `minSdkVersion=24` |
| 目标系统 | Android 16（API 36） | `build.gradle.kts:20`；APK `targetSdkVersion=36` |
| 编译 SDK | API 36 | `build.gradle.kts:9`；APK `compileSdkVersion='36'` |
| 工具链 | Flutter 3.47.8 / Dart 3.13.7 / Gradle 9.3.1 / AGP 9.1.0 / Kotlin 2.4.0 / Java 17 | `settings.gradle.kts:22-23`、`gradle-wrapper.properties:5` |

**装不上的设备**：Android 6.0.1 及以下（API ≤ 23）。

### CPU 架构

| 架构 | 是否包含 | 说明 |
| --- | --- | --- |
| `arm64-v8a`（**ARM 64 位**） | ✅ | 主流手机 |
| `armeabi-v7a`（**ARM 32 位**） | ✅ | 老机型 / 低端机 |
| `x86_64` | ✅ | 模拟器、极少数设备 |
| `x86`（32 位 Intel） | ❌ | 仅早年 Intel 平板与老模拟器受影响，真实手机不受影响 |

- ✅ 实测 APK：`lib/` 下三个目录各有 4 个 `.so`，`aapt2` 报 `native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'`
- ✅ 构建里**没有** `abiFilters` / `splits` / `ndk { }` 限制 → 打的是**通用 APK**（约 56 MB），不是分架构包
- ✅ **16KB 内存页已对齐**：`zipalign -c -P 16 4` 校验通过。Android 15+ 部分设备使用 16KB 页，未对齐会直接装不上

### GMS（Google 移动服务）

- ✅ **未发现任何 GMS 依赖**：APK 合并清单里没有 `com.google.android.gms.*` 组件或权限，
  依赖树里也没有 Play Services 相关包（只有 `androidx.startup` / `emoji2` / `lifecycle` / `profileinstaller`）。
- 因此**具备在无 GMS 环境运行的条件**（华为等无 GMS 机型）。
- ⚠️ 这只是「不依赖 GMS」，**不等于「所有华为设备均已实测通过」**。开发期间在华为
  MAG-AN00 真机上做过测试，但**该设备的 GMS 状态尚未核实**，因此不能据此认定
  「已在无 GMS 环境中验证通过」；其他华为机型、其他无 GMS 设备均属 ❓ 尚未验证。

### 权限说明

APK 里只有 2 条 `uses-permission`，**用户不需要手动授予任何权限**：

| 权限 | 类型 | 是否需要授权 |
| --- | --- | --- |
| `android.permission.INTERNET` | 普通权限（normal） | ❌ 不需要，安装即生效 |
| `com.example.chaoxing_helper.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | 构建工具**自动生成的**应用私有权限（Android 13+ 动态广播接收器隔离用） | ❌ 不需要，也不会出现在系统权限管理界面 |

**没有申请**：悬浮窗（`SYSTEM_ALERT_WINDOW`）、存储读写、通知（`POST_NOTIFICATIONS`）、
相机、位置、前台服务、开机自启。答案浮层是**应用内组件**，不是系统级悬浮窗，
所以**不会弹「请授予悬浮窗权限」**。

⚠️ `android:allowBackup` 未显式声明（系统默认 `true`）。换机恢复后，加密 Key 依赖的
Keystore 密钥不随备份迁移，旧 Key 可能读不出来（代码有容错，不会崩溃）。

### WebView 说明

- ✅ **依赖手机自带的 Android System WebView**（或 Chrome 提供的 WebView 实现），本项目不打包内核。
  链路：`flutter_inappwebview_android 1.1.3` → `androidx.webkit:webkit:1.12.0`。
- ✅ **没有「WebView 版本低于 X 就拒绝运行」的硬门槛**，插件用能力探测（`WebViewFeature`）做降级。
- ⚠️ **加载失败时没有任何用户提示**：`work_webview_page.dart` 未挂 `onReceivedError` /
  `onLoadError` / `onRenderProcessGone`，WebView 创建处也没有 try/catch。
  内核缺失、网页打不开、渲染进程崩溃时，用户看到的是**一块空白**，不会闪退，也不会告诉你为什么。

**白屏排查建议**（按顺序试）：

1. 退出重进一次该页面 —— 先排除只是没加载完。
2. 系统设置里搜「WebView」，确认 **Android System WebView** 与 **Chrome** 未被停用/卸载；
   在应用商店更新到最新版后重启 App。
3. 在同一个 App 里打开一个已知正常的站点（如 `https://www.baidu.com`）：
   能打开 → 问题在学习通侧或登录态；也打不开 → 问题在 WebView 内核/系统。
4. 确认模型地址填的是 `https://` —— 本项目禁用了明文 HTTP，`http://` 会直接失败。
5. 仍然白屏，用 `adb logcat | grep -i -E "chromium|webview|flutter"` 抓日志再反馈。

### 功能支持状态

> ✅ 有代码证据 · 🧪 已通过自动化测试（**不代表实机验证**）· ⚠️ 有限制 · ❓ 尚未验证 · ❌ 不支持

| 功能 | 状态 | 依据 |
| --- | --- | --- |
| 内置 WebView 浏览 / 返回 | ✅ | `work_webview_page.dart:1103`（WebView）、`:1070`（返回按钮 `goBack`）；**无「前进」实现** |
| 读取题干与选项文字 | ✅🧪 | `assets/js/extractor.js`、`tool/test_extractor.js` |
| 把题目文本交 AI 出参考答案 | ✅ | `ai_solver_service.dart:111-114`（**无单测**，仅代码证据） |
| 悬浮答案面板（拖拽/最小化/复制/题号切换） | ✅🧪 | `test/answer_float_panel_test.dart` |
| 提取作业列表到本地待办看板 | ✅🧪 | `assets/js/page_reader.js`、`tool/test_row_reader.js`、`test/scanner_parser_test.dart` |
| 已交作业拦截（不浪费额度） | ✅🧪 | `test/submitted_guard_test.dart` |
| 侧滑删除 + 5 秒撤销 | ✅🧪 | `dashboard_page.dart:556`、`test/dashboard_views_test.dart:298` |
| 课程快捷入口导入 | ✅🧪 | `page_reader.js` 的 `courses` 分支、`test/scanner_parser_test.dart` |
| API Key 存加密存储 | ✅🧪 | `app_config.dart:134-135`、`test/app_config_test.dart` |
| 多模型顺序重试 | ✅ | `ai_solver_service.dart:64-70`（无单测） |
| **图片题 / 带图题干** | ❌ | `extractor.js:6` 明写「不处理图片，不做 base64，不下载资源」 |
| **题目在跨域 iframe 里** | ⚠️ | 当前逻辑仅读取顶层文档，不主动遍历或读取 iframe；实际提取情况尚未完成当前版本实测（`page_reader.js:14`、`work_webview_page.dart:146-147`） |
| 一次性聚合全部课程作业 | ❌ | 见下文「关于一键提取全部课程作业」 |
| 自动点击 / 自动提交 / 保存答案 | ❌ | 红线功能，`test/readonly_guard_test.dart` 守卫 |
| 附件 / 图片下载与上传 | ❌ | 无相关代码 |
| 无 GMS 设备运行 | ❓ | 代码层不依赖 GMS；**测试设备的 GMS 状态尚未核实** |
| Android 15/16 边到边显示效果 | ❓ | `targetSdk=36` 会强制边到边；启动页无 `SafeArea`/`AppBar` |
| 全机型实机验证 | ❓ | 见下文「实机兼容性状态」 |

### 环境层面的限制

> 功能层面的三条已在「已知限制」统一列出（含代码位置），此处不再重复，只补环境相关项。

- ⚠️ 统一使用桌面版 UA，页面按桌面布局渲染，小屏手机上可能出现横向滚动。
- ❓ **Android 7~9 的 WebView 混合合成性能**（滚动、输入法体验）：尚未进行相关设备性能验证。

### AI 数据流（请务必读）

**题目文本会被发送到你自己配置的第三方 AI 服务。** 这是本工具的核心行为，不是可选项。

| 会发送 | 不会发送 |
| --- | --- |
| 每道题的**题型**、**题干文字**、**选项文字**（含标号） | Cookie / 登录态 / 账号 |
| 一条固定的系统提示词（要求输出 JSON 数组） | 页面 URL / `courseId` / `classId` / `enc` / `workId` |
| 你配置的 `model` 名与 `temperature` | 学号、姓名、学校等身份信息 |

- ✅ 证据：`ai_solver_service.dart:26-47` 只拼题型/题干/选项；`:114` 的请求体只有
  `model` / `messages` / `temperature`；请求头只有 `Authorization: Bearer <你的 Key>`。
- 请求发往**你在设置里填的 BaseUrl**，不经过作者、不经过任何中转服务。
- ⚠️ **作者无法对你的数据负责**：该第三方服务是否留存、是否用于训练、是否跨境传输，
  完全取决于你选的厂商条款。**本项目不对其作任何隐私保证。**
- ⚠️ 有些作业标题自带姓名或学号，这类文字会随题干一起发出去，请自行确认后再点「开始分析」。

### 实机兼容性状态

- ✅ **早期版本做过真机测试**：2026-10-31 及以前，在一台华为 MAG-AN00（ARM64）上完成过
  安装（含 release 包）；并在学习通登录态下验证了课程列表、作业提取和 AI 答题，
  以及悬浮面板交互与侧滑删除等。
- ❓ **当前版本尚未重新装机验证。** 此后多轮安全整改（删除自动采集脚本、改用结构化字段提取、
  API Key 迁入加密存储、WebView 收紧）之后，代码**没有再次装到真机上运行过**，
  上面的历史结论不能直接沿用到当前版本。
- ❓ 其余系统版本、厂商 ROM、32 位 ARM 设备、其他无 GMS 设备**均未实测**，全机型验证尚未完成。
- 建议优先自测：**Android 7.0 / 8.1**（最低线）、**Android 15 或 16**（边到边 + 预测性返回）、
  一台**国产 ROM**（WebView 定制）、一台**32 位 ARM 老机**（若有）。
- 任一机型出现白屏、错位、按钮点不动，请先按上面「白屏排查建议」抓一次信息再反馈。

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
> 「无权限的操作！」**。所以网页里只能「先点进课程页 → 再点作业页签」，本工具不代劳这两步。

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
4. **API Key 存在系统加密存储里**（`flutter_secure_storage`，Android 走
   EncryptedSharedPreferences，密钥由 Keystore 派生）；旧版本的明文配置会在首次启动时
   自动迁入并删除。登录 Cookie 仍是本机 `SharedPreferences` 里的明文（WebView 需要它来同步登录态），
   请勿在公用 / root 过的设备上使用，也不要随意备份该应用的 `shared_prefs` 目录。
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
node tool/test_row_reader.js
```

首次启动：点右上角 ⚙️ → 添加模型（名称 / BaseUrl / Model / API Key）→ 保存。
BaseUrl 支持只填到 `/v1`，会自动补 `/chat/completions`。

## 目录结构

```
lib/
  core/config/app_config.dart            模型列表配置（API Key 存加密存储）
  core/network/cookie_sync_helper.dart   登录态与 Cookie
  data/services/ai_solver_service.dart   多模型顺序重试的 AI 调用
  data/services/scanner_service.dart     结构化字段 → 作业/课程模型（不接收 HTML）
  data/services/submission_detector.dart  是否「已交」的判定规则（纯函数）
  data/services/task_store.dart          作业列表本地缓存
  data/services/course_store.dart        课程快捷入口本地缓存
  ui/theme/app_theme.dart                全局设计 token（配色 / 圆角 / ThemeData）
  ui/pages/dashboard_page.dart           看板 + 课程入口 + 模型设置（含侧滑删除 / 动效）
  ui/pages/work_webview_page.dart        WebView 阅读页 + 悬浮面板 + 课程导入 + 已交拦截
  ui/widgets/answer_float_panel.dart     可拖拽/最小化/一键复制的悬浮答案面板
assets/js/extractor.js                   题干/选项文字提取（只读，含去重）
assets/js/page_reader.js                 作业行 / 课程卡片字段提取（只读，输出 JSON）
test/                                    单测（解析 / 已交判据 / 看板交互 / 只读守卫）
tool/test_extractor.js                   题干提取脚本的 Node 回归测试
tool/test_row_reader.js                  页面字段提取脚本的 Node 回归测试（含隐藏内容不外泄）
```

## 免责声明

本项目按「现状」提供，不附带任何明示或暗示的担保。作者不对因使用本项目产生的
任何直接或间接损失负责，包括但不限于账号处罚、成绩认定、数据丢失等。
如果你不同意上述任何一条，请立即停止使用并删除本项目。

本项目采用 MIT 协议开源，详见 [LICENSE](LICENSE)。

本项目所使用的第三方组件及其许可证声明，详见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
