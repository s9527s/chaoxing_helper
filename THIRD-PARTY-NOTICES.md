# 第三方开源组件许可声明

本文件列出本仓库当前依赖解析结果中实际使用的第三方开源组件、其版本、许可证类型，
以及许可证原文。本仓库自身代码以 MIT 许可证发布，见 [LICENSE](LICENSE)。
第三方组件仍归各自著作权人所有，并适用各自的许可证。

## 生成与核实方式

| 项目 | 说明 |
| --- | --- |
| 版本来源 | `pubspec.lock`（当前解析结果，共 89 个条目） |
| 许可证来源 | 本机 Pub 缓存中各包目录下的 `LICENSE` 文件，逐字读取 |
| 读取路径形态 | `<PUB_CACHE>/hosted/pub.flutter-io.cn/<包名>-<版本>/LICENSE` |
| Flutter SDK 组件 | 从 SDK 内的包目录读取（`packages/<包名>/LICENSE`） |
| 版权行 | 取自各包 LICENSE 文件内的 `Copyright` 行，原样保留，未改写 |
| 未取到许可证文件的组件 | 见第六节，只记录包名、版本与原因，不填写任何推测内容 |

> 关于「许可证正文」一节的去重方式：多个包的 LICENSE 文本除 `Copyright` 行以外完全一致，
> 因此正文按「去掉版权行后的文本」比对分组，每组只收录一份**完整原文**（含该包自己的版权行）；
> 组内其余包的版权行与版本已在前面各节表格中逐条列出，未做合并或省略。

## 一、Flutter SDK 组件

| 组件 | 版本 | 依赖角色 | 许可证 | 说明 |
| --- | --- | --- | --- | --- |
| `flutter` | 0.0.0 | 运行时直接依赖 | BSD-3-Clause | 许可证原文见第七节 |
| `flutter_test` | 0.0.0 | 仅开发期 | 待核实 | 该包由 Flutter SDK 提供，其包目录内无独立 LICENSE 文件 |
| `flutter_web_plugins` | 0.0.0 | 传递依赖 | 待核实 | 该包由 Flutter SDK 提供，其包目录内无独立 LICENSE 文件 |
| `sky_engine` | 0.0.0 | 传递依赖 | 待核实 | 上游许可证文件名下是聚合声明文件（1269349 字节 / 29845 行），本文件不转抄 |

Flutter SDK 自身以 BSD-3-Clause 许可证发布，SDK 根目录 `LICENSE` 文件
（`Copyright 2014 The Flutter Authors. All rights reserved.`）已核对。
其中 `flutter` 包目录下另有内容相同的 25 行 LICENSE 文件。

## 二、直接依赖（运行时，会进入发布产物）

| 组件 | 版本 | 许可证 | 版权行（取自上游 LICENSE） |
| --- | --- | --- | --- |
| `cupertino_icons` | 1.0.9 | MIT | Copyright (c) 2016 Vladimir Kharlampidi |
| `dio` | 5.11.1 | MIT | Copyright (c) 2018 Wen Du (wendux) |
| `flutter_inappwebview` | 6.1.5 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_secure_storage` | 9.2.4 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `shared_preferences` | 2.5.6 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `url_launcher` | 6.3.3 | BSD-3-Clause | Copyright 2013 The Flutter Authors |

## 三、直接开发依赖（仅用于测试与静态分析，不进入发布产物）

| 组件 | 版本 | 许可证 | 版权行（取自上游 LICENSE） |
| --- | --- | --- | --- |
| `flutter_lints` | 6.0.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |

## 四、传递依赖（完整清单，按包名字母序）

本表覆盖 `pubspec.lock` 中全部 transitive 条目。这里只记录解析结果与上游许可证，
未逐包判定是否实际进入发布产物（该判定需要按各平台构建产物反查，本文件不做推断）。

| 组件 | 版本 | 许可证 | 版权行（取自上游 LICENSE） |
| --- | --- | --- | --- |
| `args` | 2.7.0 | BSD-3-Clause | Copyright 2013, the Dart project authors. |
| `async` | 2.13.1 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `boolean_selector` | 2.1.2 | BSD-3-Clause | Copyright 2016, the Dart project authors. |
| `characters` | 1.4.1 | BSD-3-Clause | Copyright 2019, the Dart project authors. |
| `clock` | 1.1.3 | Apache-2.0 | Copyright [yyyy] [name of copyright owner] |
| `code_assets` | 2.1.0 | BSD-3-Clause | Copyright 2025, the Dart project authors. |
| `collection` | 1.19.1 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `crypto` | 3.0.8 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `dio_web_adapter` | 2.2.2 | MIT | Copyright (c) 2018 Wen Du (wendux) |
| `fake_async` | 1.3.3 | Apache-2.0 | Copyright [yyyy] [name of copyright owner] |
| `ffi` | 2.2.0 | BSD-3-Clause | Copyright 2019, the Dart project authors. |
| `file` | 7.0.1 | BSD-3-Clause | Copyright 2017, the Dart project authors. All rights reserved. |
| `flutter_inappwebview_android` | 1.1.3 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_inappwebview_internal_annotations` | 1.3.0 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_inappwebview_ios` | 1.1.2 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_inappwebview_macos` | 1.1.2 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_inappwebview_platform_interface` | 1.3.0+1 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_inappwebview_web` | 1.1.2 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_inappwebview_windows` | 0.6.0 | Apache-2.0 | Copyright 2023 Lorenzo Pichilli |
| `flutter_secure_storage_linux` | 1.2.3 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `flutter_secure_storage_macos` | 3.1.3 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `flutter_secure_storage_platform_interface` | 1.1.2 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `flutter_secure_storage_web` | 1.2.1 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `flutter_secure_storage_windows` | 3.1.2 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `hooks` | 2.2.0 | BSD-3-Clause | Copyright 2025, the Dart project authors. |
| `http_parser` | 4.1.2 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `jni` | 1.1.0 | BSD-3-Clause | Copyright 2022, the Dart project authors. |
| `jni_flutter` | 1.0.4+1 | BSD-3-Clause | Copyright 2026, the Dart project authors. |
| `jni_util` | 1.0.0 | BSD-3-Clause | Copyright 2026, the Dart project authors. |
| `js` | 0.6.7 | BSD-3-Clause | Copyright 2012, the Dart project authors. |
| `leak_tracker` | 11.0.2 | BSD-3-Clause | Copyright 2022, the Dart project authors. |
| `leak_tracker_flutter_testing` | 3.0.10 | BSD-3-Clause | Copyright 2022, the Dart project authors. |
| `leak_tracker_testing` | 3.0.2 | BSD-3-Clause | Copyright 2022, the Dart project authors. |
| `lints` | 6.1.0 | BSD-3-Clause | Copyright 2021, the Dart project authors. |
| `logging` | 1.3.0 | BSD-3-Clause | Copyright 2013, the Dart project authors. |
| `matcher` | 0.12.20 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `material_color_utilities` | 0.13.0 | Apache-2.0 | Copyright 2021 Google LLC |
| `meta` | 1.19.0 | BSD-3-Clause | Copyright 2016, the Dart project authors. |
| `mime` | 2.1.0 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `objective_c` | 9.6.2 | BSD-3-Clause | Copyright 2024, the Dart project authors. |
| `package_config` | 3.0.0 | BSD-3-Clause | Copyright 2019, the Dart project authors. |
| `path` | 1.9.1 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `path_provider` | 2.1.6 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `path_provider_android` | 2.3.1 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `path_provider_foundation` | 2.6.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `path_provider_linux` | 2.2.2 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `path_provider_platform_interface` | 2.1.3 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `path_provider_windows` | 2.3.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `platform` | 3.2.0 | BSD-3-Clause | Copyright 2017, the Dart project authors. All rights reserved. |
| `plugin_platform_interface` | 2.1.8 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `pub_semver` | 2.2.1 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `record_use` | 1.1.1 | BSD-3-Clause | Copyright 2024, the Dart project authors. |
| `shared_preferences_android` | 2.5.4 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `shared_preferences_foundation` | 2.6.1 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `shared_preferences_linux` | 2.4.1 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `shared_preferences_platform_interface` | 2.4.2 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `shared_preferences_web` | 2.4.3 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `shared_preferences_windows` | 2.4.1 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `source_span` | 1.10.2 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `stack_trace` | 1.12.2 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `stream_channel` | 2.1.4 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `string_scanner` | 1.4.1 | BSD-3-Clause | Copyright 2014, the Dart project authors. |
| `term_glyph` | 1.2.2 | BSD-3-Clause | Copyright 2017, the Dart project authors. |
| `test_api` | 0.7.12 | BSD-3-Clause | Copyright 2018, the Dart project authors. |
| `typed_data` | 1.4.0 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `url_launcher_android` | 6.3.33 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `url_launcher_ios` | 6.4.2 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `url_launcher_linux` | 3.2.3 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `url_launcher_macos` | 3.2.6 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `url_launcher_platform_interface` | 2.3.2 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `url_launcher_web` | 2.4.3 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `url_launcher_windows` | 3.1.6 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `vector_math` | 2.4.4 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `vm_service` | 15.4.0 | BSD-3-Clause | Copyright 2015, the Dart project authors. |
| `web` | 1.1.2 | BSD-3-Clause | Copyright 2023, the Dart project authors. |
| `win32` | 5.15.0 | BSD-3-Clause | Copyright (c) 2024, Halil Durmus |
| `xdg_directories` | 1.1.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors. All rights reserved. |
| `yaml` | 3.1.4 | MIT | Copyright (c) 2014, the Dart project authors. |

## 五、Apache-2.0 组件的 NOTICE 情况

Apache-2.0 组件共 11 个：

- `clock` 1.1.3
- `fake_async` 1.3.3
- `flutter_inappwebview` 6.1.5
- `flutter_inappwebview_android` 1.1.3
- `flutter_inappwebview_internal_annotations` 1.3.0
- `flutter_inappwebview_ios` 1.1.2
- `flutter_inappwebview_macos` 1.1.2
- `flutter_inappwebview_platform_interface` 1.3.0+1
- `flutter_inappwebview_web` 1.1.2
- `flutter_inappwebview_windows` 0.6.0
- `material_color_utilities` 0.13.0

经检查，上述各包目录内只有 `LICENSE` 文件，没有任何 `NOTICE` 文件。
各包 `LICENSE` 原文见第七节。

## 六、未取得独立许可证文件的组件（待核实）

以下组件无法从上游安装目录取到独立的许可证文件。按本文件的原则，
**不对其许可证类型做任何推断或补写**，仅记录包名、版本与原因：

| 组件 | 版本 | 待核实原因 |
| --- | --- | --- |
| `flutter_test` | 0.0.0 | 该包由 Flutter SDK 提供，其包目录内无独立 LICENSE 文件 |
| `flutter_web_plugins` | 0.0.0 | 该包由 Flutter SDK 提供，其包目录内无独立 LICENSE 文件 |
| `sky_engine` | 0.0.0 | 上游许可证文件名下是聚合声明文件（1269349 字节 / 29845 行），本文件不转抄 |

补充事实（仅陈述已核对到的内容，不含推断）：

- Flutter SDK 根目录存在 `LICENSE`（BSD-3-Clause，`Copyright 2014 The Flutter Authors.`）。
- `flutter_test` 与 `flutter_web_plugins` 位于 SDK 的 `packages/` 下，其包目录内没有 `LICENSE` 文件。
- `sky_engine` 包目录下的 `license` 文件为 1,269,349 字节 / 29,844 行，
  内容为 Flutter 引擎汇总的第三方声明清单，体量远超本文件可转抄范围，故未收录原文；
  如需完整声明，请直接查阅 Flutter SDK 内该文件。

## 七、许可证正文（从上游 LICENSE 文件逐字复制，未改写、未翻译）

共 11 组不同正文，覆盖 86 个组件。

### 7.1 BSD-3-Clause（组 1，35 个组件）

覆盖组件：

- `args` 2.7.0 — Copyright 2013, the Dart project authors.
- `async` 2.13.1 — Copyright 2015, the Dart project authors.
- `boolean_selector` 2.1.2 — Copyright 2016, the Dart project authors.
- `characters` 1.4.1 — Copyright 2019, the Dart project authors.
- `code_assets` 2.1.0 — Copyright 2025, the Dart project authors.
- `collection` 1.19.1 — Copyright 2015, the Dart project authors.
- `crypto` 3.0.8 — Copyright 2015, the Dart project authors.
- `ffi` 2.2.0 — Copyright 2019, the Dart project authors.
- `hooks` 2.2.0 — Copyright 2025, the Dart project authors.
- `http_parser` 4.1.2 — Copyright 2014, the Dart project authors.
- `jni` 1.1.0 — Copyright 2022, the Dart project authors.
- `jni_flutter` 1.0.4+1 — Copyright 2026, the Dart project authors.
- `jni_util` 1.0.0 — Copyright 2026, the Dart project authors.
- `js` 0.6.7 — Copyright 2012, the Dart project authors.
- `leak_tracker` 11.0.2 — Copyright 2022, the Dart project authors.
- `leak_tracker_flutter_testing` 3.0.10 — Copyright 2022, the Dart project authors.
- `leak_tracker_testing` 3.0.2 — Copyright 2022, the Dart project authors.
- `lints` 6.1.0 — Copyright 2021, the Dart project authors.
- `logging` 1.3.0 — Copyright 2013, the Dart project authors.
- `matcher` 0.12.20 — Copyright 2014, the Dart project authors.
- `meta` 1.19.0 — Copyright 2016, the Dart project authors.
- `mime` 2.1.0 — Copyright 2015, the Dart project authors.
- `objective_c` 9.6.2 — Copyright 2024, the Dart project authors.
- `package_config` 3.0.0 — Copyright 2019, the Dart project authors.
- `path` 1.9.1 — Copyright 2014, the Dart project authors.
- `pub_semver` 2.2.1 — Copyright 2014, the Dart project authors.
- `record_use` 1.1.1 — Copyright 2024, the Dart project authors.
- `source_span` 1.10.2 — Copyright 2014, the Dart project authors.
- `stack_trace` 1.12.2 — Copyright 2014, the Dart project authors.
- `stream_channel` 2.1.4 — Copyright 2015, the Dart project authors.
- `string_scanner` 1.4.1 — Copyright 2014, the Dart project authors.
- `term_glyph` 1.2.2 — Copyright 2017, the Dart project authors.
- `test_api` 0.7.12 — Copyright 2018, the Dart project authors.
- `typed_data` 1.4.0 — Copyright 2015, the Dart project authors.
- `vm_service` 15.4.0 — Copyright 2015, the Dart project authors.

```text
Copyright 2013, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 7.2 BSD-3-Clause（组 2，26 个组件）

覆盖组件：

- `flutter` 0.0.0 — Copyright 2014 The Flutter Authors. All rights reserved.
- `flutter_lints` 6.0.0 — Copyright 2013 The Flutter Authors. All rights reserved.
- `path_provider` 2.1.6 — Copyright 2013 The Flutter Authors
- `path_provider_android` 2.3.1 — Copyright 2013 The Flutter Authors
- `path_provider_foundation` 2.6.0 — Copyright 2013 The Flutter Authors
- `path_provider_linux` 2.2.2 — Copyright 2013 The Flutter Authors
- `path_provider_platform_interface` 2.1.3 — Copyright 2013 The Flutter Authors
- `path_provider_windows` 2.3.0 — Copyright 2013 The Flutter Authors. All rights reserved.
- `plugin_platform_interface` 2.1.8 — Copyright 2013 The Flutter Authors. All rights reserved.
- `shared_preferences` 2.5.6 — Copyright 2013 The Flutter Authors
- `shared_preferences_android` 2.5.4 — Copyright 2013 The Flutter Authors
- `shared_preferences_foundation` 2.6.1 — Copyright 2013 The Flutter Authors
- `shared_preferences_linux` 2.4.1 — Copyright 2013 The Flutter Authors. All rights reserved.
- `shared_preferences_platform_interface` 2.4.2 — Copyright 2013 The Flutter Authors
- `shared_preferences_web` 2.4.3 — Copyright 2013 The Flutter Authors. All rights reserved.
- `shared_preferences_windows` 2.4.1 — Copyright 2013 The Flutter Authors. All rights reserved.
- `url_launcher` 6.3.3 — Copyright 2013 The Flutter Authors
- `url_launcher_android` 6.3.33 — Copyright 2013 The Flutter Authors
- `url_launcher_ios` 6.4.2 — Copyright 2013 The Flutter Authors
- `url_launcher_linux` 3.2.3 — Copyright 2013 The Flutter Authors
- `url_launcher_macos` 3.2.6 — Copyright 2013 The Flutter Authors
- `url_launcher_platform_interface` 2.3.2 — Copyright 2013 The Flutter Authors. All rights reserved.
- `url_launcher_web` 2.4.3 — Copyright 2013 The Flutter Authors
- `url_launcher_windows` 3.1.6 — Copyright 2013 The Flutter Authors
- `vector_math` 2.4.4 — Copyright 2013 The Flutter Authors
- `xdg_directories` 1.1.0 — Copyright 2013 The Flutter Authors. All rights reserved.

```text
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 7.3 Apache-2.0（组 3，10 个组件）

覆盖组件：

- `clock` 1.1.3 — Copyright [yyyy] [name of copyright owner]
- `fake_async` 1.3.3 — Copyright [yyyy] [name of copyright owner]
- `flutter_inappwebview` 6.1.5 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_android` 1.1.3 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_internal_annotations` 1.3.0 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_ios` 1.1.2 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_macos` 1.1.2 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_platform_interface` 1.3.0+1 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_web` 1.1.2 — Copyright 2023 Lorenzo Pichilli
- `flutter_inappwebview_windows` 0.6.0 — Copyright 2023 Lorenzo Pichilli

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

### 7.4 BSD-3-Clause（组 4，6 个组件）

覆盖组件：

- `flutter_secure_storage` 9.2.4 — Copyright 2017 German Saprykin
- `flutter_secure_storage_linux` 1.2.3 — Copyright 2017 German Saprykin
- `flutter_secure_storage_macos` 3.1.3 — Copyright 2017 German Saprykin
- `flutter_secure_storage_platform_interface` 1.1.2 — Copyright 2017 German Saprykin
- `flutter_secure_storage_web` 1.2.1 — Copyright 2017 German Saprykin
- `flutter_secure_storage_windows` 3.1.2 — Copyright 2017 German Saprykin

```text
BSD 3-Clause License

Copyright 2017 German Saprykin
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 7.5 MIT（组 5，2 个组件）

覆盖组件：

- `dio` 5.11.1 — Copyright (c) 2018 Wen Du (wendux)
- `dio_web_adapter` 2.2.2 — Copyright (c) 2018 Wen Du (wendux)

```text
MIT License

Copyright (c) 2018 Wen Du (wendux)
Copyright (c) 2022 The CFUG Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### 7.6 BSD-3-Clause（组 6，2 个组件）

覆盖组件：

- `file` 7.0.1 — Copyright 2017, the Dart project authors. All rights reserved.
- `platform` 3.2.0 — Copyright 2017, the Dart project authors. All rights reserved.

```text
Copyright 2017, the Dart project authors. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 7.7 BSD-3-Clause（组 7，1 个组件）

覆盖组件：

- `web` 1.1.2 — Copyright 2023, the Dart project authors.

```text
Copyright 2023, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 7.8 MIT（组 8，1 个组件）

覆盖组件：

- `cupertino_icons` 1.0.9 — Copyright (c) 2016 Vladimir Kharlampidi

```text
The MIT License (MIT)

Copyright (c) 2016 Vladimir Kharlampidi

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### 7.9 Apache-2.0（组 9，1 个组件）

覆盖组件：

- `material_color_utilities` 0.13.0 — Copyright 2021 Google LLC

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

   To apply the Apache License to your work, attach the following
   boilerplate notice, with the fields enclosed by brackets "[]"
   replaced with your own identifying information. (Don't include
   the brackets!)  The text should be enclosed in the appropriate
   comment syntax for the file format. We also recommend that a
   file or class name and description of purpose be included on the
   same "printed page" as the copyright notice for easier
   identification within third-party archives.

   Copyright 2021 Google LLC

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

### 7.10 BSD-3-Clause（组 10，1 个组件）

覆盖组件：

- `win32` 5.15.0 — Copyright (c) 2024, Halil Durmus

```text
BSD 3-Clause License

Copyright (c) 2024, Halil Durmus

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 7.11 MIT（组 11，1 个组件）

覆盖组件：

- `yaml` 3.1.4 — Copyright (c) 2014, the Dart project authors.

```text
Copyright (c) 2014, the Dart project authors.
Copyright (c) 2006, Kirill Simonov.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 八、本文件刻意未做的事

- 未根据包名、常见惯例或记忆推断任何组件的许可证类型；取不到文件的一律列为待核实。
- 未改写、翻译或摘录许可证正文，第七节内容为上游文件逐字复制。
- 未逐包判定是否进入发布产物（见第四节说明）。
- 本文件不构成法律意见。发布二进制产物前，如对 Apache-2.0 组件的 NOTICE 义务、
  或 Flutter 引擎声明清单的处理方式有疑问，请咨询专业人士。
