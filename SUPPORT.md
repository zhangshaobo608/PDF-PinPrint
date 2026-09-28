# PDF拼印支持

## 系统要求

- macOS 13 或更高版本
- Apple 芯片或 Intel Mac

## 基本使用

1. 点击“添加文件…”或将 PDF、图片、Word 文档拖入窗口。支持 PDF、PNG、JPG、JPEG、TIFF、GIF、BMP、HEIC、WebP、DOCX、DOC、RTF、RTFD 和 TXT。
2. 如需只用某份文件的部分页面，点击该文件下方“全部 N 页”，选择“指定页面”，输入 `1,3,5-7` 等原始页码。每份文件可分别选择。
3. 设置每面页数、纸张、方向、排列方式和边距。
4. 在“打印预览”中检查拼版结果。
5. 点击“打印…”进入 macOS 系统打印窗口，或选择“另存拼版 PDF…”。

多份 PDF 会按文件名顺序组成连续页面队列。系统打印窗口中的“每张页数”应保持为 1，因为应用已经完成拼版。
“原文档”视图保留导入后的完整页面；预览、打印与导出只包含各文件选中的页。修改某文件选页后，“更多设置”中的整体页码范围会恢复为全部，撤销可恢复此前状态。源文件不会被修改。

## 获取帮助

请在 [GitHub Issues](https://github.com/zhangshaobo608/PDF-PinPrint/issues) 提交问题，并说明 macOS 版本、操作步骤和实际表现。请勿上传包含隐私信息的 PDF 文件。

---

# PDF Merge & Print Support

## Requirements

- macOS 13 or later
- Apple silicon or Intel Mac

## Basic use

1. Click “Add Documents…” or drag PDFs, images, or Word documents into the window. Supported formats include PDF, PNG, JPG, JPEG, TIFF, GIF, BMP, HEIC, WebP, DOCX, DOC, RTF, RTFD, and TXT.
2. To use only some pages from a document, click “All N pages” under that file, choose “Selected Pages,” and enter original page numbers such as `1,3,5-7`. You can select pages independently for each file.
3. Set pages per sheet, paper, orientation, arrangement, and margins.
4. Check the imposed result in “Print Preview”.
5. Click “Print…” to open the native macOS print dialog, or choose “Export imposed PDF…”.

Multiple PDFs are processed as one continuous page queue in filename order. Keep the system print dialog’s pages-per-sheet setting at 1 because the app has already imposed the pages.
“Original document” keeps every imported page visible; the print preview, printout, and export include only selected pages. Changing a file’s selection resets the combined page range under More Settings to All Pages; Undo restores the prior state. Original files are never modified.

## Get help

Open a [GitHub Issue](https://github.com/zhangshaobo608/PDF-PinPrint/issues) with your macOS version, steps to reproduce, and the observed result. Do not upload PDFs that contain private information.
