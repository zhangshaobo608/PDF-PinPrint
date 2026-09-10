# PDF拼印

一个轻量的原生 macOS PDF 预览与拼版打印工具，解决系统打印面板无法选择每张纸打印 3、5 等奇数页的问题。

[隐私政策](PRIVACY.md) · [使用支持](SUPPORT.md)

## 功能

- 一次选择或拖入多个 PDF，查看全部原页与打印预览
- 按文件名顺序组成连续页队列，无需先保存合并 PDF
- 每张纸单面可放 1-16 页，默认 3 页
- 支持上下单列、左右单行和自动网格排列
- 支持 A4、A3、Letter 与横竖纸张方向
- 可选择原 PDF 页码范围
- 可显示页面边框
- 调用 macOS 系统打印面板完成打印
- 可另存为已经拼版的 PDF
- 完全本地处理，不上传文件

## 使用

1. 选择一个或多个 PDF；多文件会按文件名顺序排列。
2. 设置“每面放几页”、纸张方向与排列方式。
3. 在右侧检查打印预览。
4. 点击“打印…”。系统打印窗口中的“布局”保持“每张 1 页”，因为 App 已经完成拼版。

## 系统要求

- macOS 13 或更高版本
- Apple 芯片或 Intel Mac

## 本地构建

需要安装 Xcode：

```bash
bash build.sh
```

构建结果位于 `dist/`。生成的 App 使用本机临时签名，适合本地使用；对外分发需要 Apple Developer ID 签名与公证。

## Mac App Store 构建

仓库包含 `PDFPinPrint.xcodeproj` 和应用沙盒配置。使用 Xcode 打开工程，在 Signing & Capabilities 中选择自己的开发团队，然后执行 Product > Archive。发布目标使用 Bundle ID `com.songningning.pdfpinprint`。

沙盒仅申请用户所选文件的读写权限与打印权限，PDF 内容仍完全在本机处理。

## 技术实现

使用 Swift、AppKit 与系统 PDFKit。拼版结果保持 PDF 矢量内容，不会先把页面转换为截图。
