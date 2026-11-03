# YoPDF Research Workspace — P0-B 分屏需求修订

本文是此前 Multi-Tab + Split Pane 任务的正式需求修订，作为 P0-B 的实现范围与验收基线。

## 发布范围

- **P0-A** 继续负责 Multi-Tab、文档生命周期和基础数据模型。
- **P0-B** 的首个可发布版本必须同时支持 Toolbar、Context Menu 和 Drag & Drop 三种分屏入口。拖拽属于 P0-B 必需功能，不得延期到 P0-C 或后续版本。
- P0-B 只有在三种入口及其安全、交互和状态保留验证全部通过后，才能标记为 **Ready for Review**。

三种入口：

1. Toolbar：`Split Right` / `Split Down`。
2. Context Menu：`Open in Split Right` / `Open in Split Down`。
3. Drag & Drop：拖拽已打开的 PDF Pane 或 Finder 中的本地 PDF 文件创建分屏。

## 拖拽来源与目标

允许的来源：

- 已打开 PDF 的 Pane 标题栏。
- 仅包含一个 PDF Pane 的 Workspace Tab。
- Finder 中的本地 PDF 文件。

在目标 Pane 上提供四个方向的 Drop Zone：`Left`、`Right`、`Top`、`Bottom`，分别在目标 Pane 对应一侧创建 Pane。拖动经过目标时显示清晰的半透明布局预览；只有松开后才提交布局变更。多 Pane Workspace Tab 不得被当成单个 PDF 随意拆分。

## 必须保留的语义

- 拖动已打开 PDF Pane 是移动现有 Session，不是重新打开文件。
- 移动后保留页码、缩放、搜索状态、注释编辑状态及未提交 Note 草稿。
- 不得因拖拽产生两个未经协调的独立可编辑实例。
- 拖动 Finder 文件时，先验证文件可打开，再提交布局变更。
- 文件打开失败、权限不足或取消拖拽时，原布局和原文档状态保持不变。
- 普通 PDF 文本选择和注释拖动不能误触发 Pane 拖拽。
- 不得通过 Drop Zone 覆盖目标 Pane 中尚未保存的工作。
- Pane 移出原 Tab 后须正确处理原布局；原 Tab 变空时不得释放已移动的 PDF Session。
- 拖拽期间或取消后不得泄漏安全范围文件访问权限。
- 移动或打开成功后，新 Pane 成为 Active Pane。

## 拒绝条件与反馈

- 达到首版允许的 Pane 数量上限时，拒绝继续拆分并给出明确反馈。
- 窗口尺寸不足以维持合理的 PDF 阅读宽度时，拒绝不适合的拆分方向并给出明确反馈。
- 拒绝或取消操作不能改变原布局或丢失原文档状态。

## P0-B 验收门槛

必须验证以下场景：

1. Pane 分别拖到目标的 Left、Right、Top、Bottom 区域。
2. 将仅含一个 PDF Pane 的 Workspace Tab 拖入其他工作区。
3. 将 Finder PDF 拖入并创建分屏。
4. 取消拖拽后布局不变。
5. 文件打开失败后布局与原文档状态不变。
6. 拖动含未保存注释的 PDF 后，编辑状态完整保留。
7. 拖动含未提交 Note 草稿的 Pane 后，草稿不丢失。
8. 拖拽完成后，Save、Undo、Find 等命令作用于正确的 Active Pane。
9. Pane 数量达到上限及窗口过窄时正确拒绝，并提供明确反馈。
10. 鼠标与触控板拖拽均可用，预览不干扰 PDFKit 的常规交互。

因此，不能以“工具栏和右键分屏已完成，拖拽将在后续 PR 实现”为由宣布 P0-B 完成。
