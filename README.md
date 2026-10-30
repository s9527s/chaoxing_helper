# Chaoxing Helper（AI 阅读辅助器）

> **本项目仅供 Flutter + WebView 技术学习与交流，不包含任何自动点击与绕过风控功能。**

一个用 Flutter 写的「网页阅读 + AI 辅助理解」实验项目：在内置 WebView 里打开学习通页面，
读取当前页的**题干文字**，交给用户自己配置的大模型给出**参考答案**，用户对照答案自行作答。

---

## 能力边界（请先读这段）

**会做的事**

- 用 `InAppWebView` 打开网页，正常浏览、前进后退
- 读取**当前页面的题干与选项文字**（纯读取，不修改 DOM）
- 把文字发给用户自己配置的 OpenAI 兼容模型（DeepSeek / Kimi / 豆包 / 任意中转站）
- 以清单形式展示「第 N 题：答案」，供用户**自己对照页面手动作答**
- 从作业列表页导入作业条目，在本地做一个待办看板

**不会做的事**

- ❌ 不会点击任何选项 / 按钮（源码里没有任何 `.click()`）
- ❌ 不会向网页写入内容（不碰 `innerHTML`、不操作富文本编辑器）
- ❌ 不会自动提交、不会点「保存」
- ❌ 没有指纹伪装、没有 `navigator.webdriver` 抹除、不绕过任何风控或验证码
- ❌ 不内置任何账号、Cookie 或题库

**已知限制**

- 题目提取只读**顶层文档**，题目在 iframe 内的页面会提取不到（这是刻意做的简化）
- 只读取文字，**不处理图片**：纯图片题无法分析
- 应用不会保存答题记录，导入的作业列表只存在内存中

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
```

首次启动：点右上角 ⚙️ → 添加模型（名称 / BaseUrl / Model / API Key）→ 保存。
BaseUrl 支持只填到 `/v1`，会自动补 `/chat/completions`。

## 目录结构

```
lib/
  core/config/app_config.dart            模型列表配置（本地持久化）
  core/network/cookie_sync_helper.dart   登录态与 Cookie
  data/services/ai_solver_service.dart   多模型顺序重试的 AI 调用
  data/services/scanner_service.dart     HTML 解析
  ui/pages/dashboard_page.dart           看板 + 模型设置
  ui/pages/work_webview_page.dart        WebView 阅读页 + 答案清单
assets/js/extractor.js                   题干文字提取（只读）
```

## 免责声明

本项目按「现状」提供，不附带任何明示或暗示的担保。作者不对因使用本项目产生的
任何直接或间接损失负责，包括但不限于账号处罚、成绩认定、数据丢失等。
如果你不同意上述任何一条，请立即停止使用并删除本项目。
