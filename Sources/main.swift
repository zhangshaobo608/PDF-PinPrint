import AppKit
import PDFKit
import UniformTypeIdentifiers

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfURLs.isEmpty else { return false }
        onDrop?(pdfURLs)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var appIcon: NSImage?
    let pdfView = PDFView()
    let thumbnailView = PDFThumbnailView()
    let sourceTitle = NSTextField(labelWithString: "尚未打开 PDF")
    let sourceDetail = NSTextField(labelWithString: "文件仅在本机处理")
    let countField = NSTextField(string: "3")
    let countStepper = NSStepper()
    let paperPopup = NSPopUpButton()
    let orientation = NSSegmentedControl(labels: ["纵向", "横向"], trackingMode: .selectOne, target: nil, action: nil)
    let arrangement = NSPopUpButton()
    let margins = NSPopUpButton()
    let borderCheckbox = NSButton(checkboxWithTitle: "显示边框", target: nil, action: nil)
    let rangeField = NSTextField(string: "")
    let mode = NSSegmentedControl(labels: ["原 PDF", "打印预览"], trackingMode: .selectOne, target: nil, action: nil)
    let summary = NSTextField(wrappingLabelWithString: "设置好后，即可预览并打印。")
    let detail = NSTextField(wrappingLabelWithString: "每面 3 页，支持任意 1–16 页。")
    let status = NSTextField(labelWithString: "")
    let pageLabel = NSTextField(labelWithString: "")
    let emptyView = NSStackView()
    let printButton = NSButton(title: "打印…", target: nil, action: nil)
    let exportButton = NSButton(title: "另存拼版 PDF…", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    var sourceDocument: PDFDocument?
    var sourceItems: [PDFSource] = []
    var sourceURLs: [URL] = []
    var outputDocument: PDFDocument?
    var outputData: Data?
    var outputSettings: PrintSettings?
    var revision = 0
    let renderQueue = OperationQueue()
    var pendingRender: DispatchWorkItem?
    var pendingOpenURLs: [URL] = []
    var controls: [NSControl] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.url(forResource: (iconName as NSString).deletingPathExtension, withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            appIcon = icon
            NSApp.applicationIconImage = icon
        }
        renderQueue.maxConcurrentOperationCount = 1
        renderQueue.qualityOfService = .userInitiated
        makeMenu()
        makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let argumentURLs = CommandLine.arguments.dropFirst()
            .filter { $0.lowercased().hasSuffix(".pdf") }
            .map { URL(fileURLWithPath: $0) }
        let initialURLs = pendingOpenURLs + argumentURLs
        if !initialURLs.isEmpty { openPDFs(initialURLs) }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.filter { $0.lowercased().hasSuffix(".pdf") }.map { URL(fileURLWithPath: $0) }
        if window == nil { pendingOpenURLs.append(contentsOf: urls) }
        else if !urls.isEmpty { openPDFs(urls) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { renderQueue.cancelAllOperations() }

    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "关于 PDF拼印", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PDF拼印", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        for (title, action, key) in [("选择 PDF…", #selector(openPanel), "o"),
                                     ("另存拼版 PDF…", #selector(exportPDF), "s"),
                                     ("打印…", #selector(printPDF), "p")] {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = appIcon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printPDF) || menuItem.action == #selector(exportPDF) {
            return outputDocument != nil
        }
        return true
    }

    func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .medium) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    func section(_ title: String, _ control: NSView) -> NSStackView {
        let stack = NSStackView(views: [label(title), control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PDF拼印"
        window.minSize = NSSize(width: 850, height: 760)
        window.center()
        let root = DropView()
        root.onDrop = { [weak self] urls in self?.openPDFs(urls) }
        window.contentView = root
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        let right = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [sidebar, divider, right] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 260),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor), right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.topAnchor.constraint(equalTo: root.topAnchor), right.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sourceTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sourceTitle.lineBreakMode = .byTruncatingMiddle
        sourceTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceDetail.font = .systemFont(ofSize: 11)
        sourceDetail.textColor = .secondaryLabelColor
        let open = button("选择多个 PDF…", #selector(openPanel))
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        let title = label("PDF拼印", size: 23, weight: .bold)
        let subtitle = label("每张纸，放你想要的页数。", size: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        countField.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        countField.alignment = .center
        countField.delegate = self
        countField.setAccessibilityLabel("每面 PDF 页数")
        countField.heightAnchor.constraint(equalToConstant: 38).isActive = true
        countStepper.minValue = 1
        countStepper.maxValue = 16
        countStepper.integerValue = 3
        countStepper.increment = 1
        countStepper.valueWraps = false
        countStepper.target = self
        countStepper.action = #selector(stepCount)
        let countRow = NSStackView(views: [countField, countStepper])
        countRow.spacing = 8
        countField.widthAnchor.constraint(equalToConstant: 176).isActive = true
        paperPopup.addItems(withTitles: ["A4 · 210 × 297 mm", "A3 · 297 × 420 mm", "Letter · 8.5 × 11 in"])
        orientation.selectedSegment = 0
        orientation.segmentDistribution = .fillEqually
        arrangement.addItems(withTitles: ["自动适配（网格）", "上下排列（单列）", "左右排列（单行）"])
        arrangement.selectItem(at: 1)
        margins.addItems(withTitles: ["标准 · 10 mm", "窄 · 5 mm", "宽 · 15 mm"])
        rangeField.placeholderString = "全部，或 1-6, 8"
        rangeField.delegate = self
        rangeField.setAccessibilityLabel("合并顺序中的页码范围")
        borderCheckbox.toolTip = "沿每个 PDF 页面边缘添加细边框，预览、打印及导出均生效。"
        for control in [paperPopup, orientation, arrangement, margins, borderCheckbox] as [NSControl] {
            control.target = self; control.action = #selector(settingsChanged)
        }
        controls = [countField, countStepper, paperPopup, orientation, arrangement, margins, borderCheckbox, rangeField]
        let hint = label("PDF 页 / 纸张单面 · 可输入 1–16", size: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        let countGroup = NSStackView(views: [label("每面放几页"), countRow, hint])
        countGroup.orientation = .vertical; countGroup.alignment = .leading; countGroup.spacing = 7
        let stack = NSStackView(views: [title, subtitle, open, sourceTitle, sourceDetail, countGroup,
            section("纸张", paperPopup), section("纸张方向", orientation),
            section("页内排列", arrangement), section("边距", margins), borderCheckbox, section("打印页码（合并顺序）", rangeField)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(19, after: subtitle)
        stack.setCustomSpacing(3, after: sourceTitle)
        stack.setCustomSpacing(20, after: sourceDetail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        for view in [open, sourceTitle, sourceDetail, countGroup] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for view in stack.arrangedSubviews where view is NSStackView { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        printButton.target = self; printButton.action = #selector(printPDF); printButton.bezelStyle = .rounded
        printButton.controlSize = .large; printButton.hasDestructiveAction = false
        printButton.bezelColor = .controlAccentColor
        exportButton.target = self; exportButton.action = #selector(exportPDF); exportButton.bezelStyle = .rounded
        let actions = NSStackView(views: [printButton, exportButton])
        actions.orientation = .vertical; actions.spacing = 8; actions.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(actions)
        printButton.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        exportButton.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 23),
            actions.leadingAnchor.constraint(equalTo: stack.leadingAnchor), actions.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            actions.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 18)
        ])
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(changeMode)
        let fit = button("适合窗口", #selector(fitPage))
        let minus = button("−", #selector(zoomOut))
        let plus = button("+", #selector(zoomIn))
        let topBar = NSStackView(views: [mode, NSView(), minus, plus, fit])
        topBar.spacing = 8; topBar.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(topBar)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(pdfView)
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 66, height: 90)
        thumbnailView.backgroundColor = .windowBackgroundColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(thumbnailView)
        let bottom = NSStackView(views: [button("上一页", #selector(previousPage)), pageLabel,
                                       button("下一页", #selector(nextPage)), NSView(), spinner])
        bottom.translatesAutoresizingMaskIntoConstraints = false; bottom.spacing = 12
        right.addSubview(bottom)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        summary.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let info = NSStackView(views: [summary, detail, status])
        info.orientation = .vertical; info.alignment = .leading; info.spacing = 4
        info.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(info)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: right.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 18), topBar.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -18),
            topBar.heightAnchor.constraint(equalToConstant: 30),
            thumbnailView.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 8), thumbnailView.widthAnchor.constraint(equalToConstant: 84),
            thumbnailView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12), thumbnailView.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            pdfView.topAnchor.constraint(equalTo: thumbnailView.topAnchor), pdfView.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 4),
            pdfView.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -12), pdfView.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20), bottom.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -12), bottom.heightAnchor.constraint(equalToConstant: 24),
            info.leadingAnchor.constraint(equalTo: bottom.leadingAnchor), info.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            info.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -18)
        ])
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        let emptyTitle = label("三页一张，也可以。", size: 25, weight: .semibold)
        let emptyText = label("选择或拖入多个 PDF，按顺序拼版打印。", size: 13, weight: .regular)
        emptyText.textColor = .secondaryLabelColor
        emptyView.setViews([icon, emptyTitle, emptyText, button("选择多个 PDF…", #selector(openPanel))], in: .center)
        emptyView.orientation = .vertical; emptyView.spacing = 18; emptyView.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(emptyView)
        NSLayoutConstraint.activate([emptyView.centerXAnchor.constraint(equalTo: right.centerXAnchor),
                                     emptyView.centerYAnchor.constraint(equalTo: right.centerYAnchor, constant: -30)])
        NotificationCenter.default.addObserver(self, selector: #selector(updatePageLabel), name: .PDFViewPageChanged, object: pdfView)
        updateAvailability()
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "可选择多个 PDF，应用会按文件名顺序连续拼版。"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, !panel.urls.isEmpty { self?.openPDFs(panel.urls) }
        }
    }
    func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
    func openPDFs(_ urls: [URL]) {
        do {
            let orderedURLs = Array(Set(urls.map(\.standardizedFileURL))).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            guard !orderedURLs.isEmpty else { return }
            var items: [PDFSource] = []
            let previewDocument = PDFDocument()
            for url in orderedURLs {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let document = PDFDocument(data: data) else {
                    throw LayoutError.message("“\(url.lastPathComponent)”不是可读取的 PDF。")
                }
                var password: String?
                if document.isLocked {
                    let alert = NSAlert(); alert.messageText = "输入 PDF 密码"; alert.informativeText = url.lastPathComponent
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    alert.accessoryView = field; alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
                    alert.window.initialFirstResponder = field
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    password = field.stringValue
                    guard document.unlock(withPassword: password!) else {
                        throw LayoutError.message("“\(url.lastPathComponent)”的密码不正确。")
                    }
                }
                guard document.pageCount > 0 else {
                    throw LayoutError.message("“\(url.lastPathComponent)”中没有页面。")
                }
                items.append(PDFSource(data: data, password: password, name: url.lastPathComponent,
                                       pageCount: document.pageCount, allowsPrinting: document.allowsPrinting))
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex), let copy = page.copy() as? PDFPage else {
                        throw LayoutError.message("无法读取“\(url.lastPathComponent)”的第 \(pageIndex + 1) 页。")
                    }
                    previewDocument.insert(copy, at: previewDocument.pageCount)
                }
            }
            sourceItems = items; sourceDocument = previewDocument; sourceURLs = orderedURLs
            if items.count == 1 {
                sourceTitle.stringValue = items[0].name
                sourceDetail.stringValue = "共 \(previewDocument.pageCount) 页 · 本地处理"
                window.title = "\(items[0].name) — PDF拼印"
                window.representedURL = orderedURLs[0]
            } else {
                sourceTitle.stringValue = "已选择 \(items.count) 个 PDF"
                sourceDetail.stringValue = "共 \(previewDocument.pageCount) 页 · 按文件名顺序 · 本地处理"
                window.title = "\(items.count) 个 PDF — PDF拼印"
                window.representedURL = nil
            }
            sourceTitle.toolTip = orderedURLs.map(\.path).joined(separator: "\n")
            rangeField.stringValue = ""
            emptyView.isHidden = true
            pdfView.document = previewDocument
            mode.selectedSegment = 1
            regenerate()
        } catch { showError(error.localizedDescription) }
    }

    func readSettings() throws -> PrintSettings {
        guard let n = Int(countField.stringValue.trimmingCharacters(in: .whitespaces)), (1...16).contains(n) else {
            throw LayoutError.message("每面页数请输入 1–16 的整数。")
        }
        var settings = PrintSettings()
        settings.pagesPerSheet = n; settings.paperIndex = paperPopup.indexOfSelectedItem
        settings.landscape = orientation.selectedSegment == 1
        settings.arrangement = arrangement.indexOfSelectedItem
        settings.margin = [CGFloat(10), 5, 15][margins.indexOfSelectedItem] * 72 / 25.4
        settings.showsBorders = borderCheckbox.state == .on
        settings.pageIndices = try Imposition.pageIndices(rangeField.stringValue, count: sourceDocument?.pageCount ?? 0)
        return settings
    }
    @objc func stepCount() { countField.integerValue = countStepper.integerValue; regenerate() }
    @objc func settingsChanged() { regenerate() }
    func controlTextDidChange(_ notification: Notification) {
        if let n = Int(countField.stringValue), (1...16).contains(n) { countStepper.integerValue = n }
        invalidateOutput()
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.regenerate() }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func invalidateOutput() {
        revision += 1
        renderQueue.cancelAllOperations()
        outputDocument = nil; outputData = nil; outputSettings = nil
        if mode.selectedSegment == 1 { pdfView.document = nil }
        updateAvailability()
    }
    func regenerate() {
        pendingRender?.cancel()
        invalidateOutput()
        guard !sourceItems.isEmpty else { return }
        let settings: PrintSettings
        do { settings = try readSettings() }
        catch {
            spinner.stopAnimation(nil); summary.stringValue = "请检查打印设置"
            detail.stringValue = error.localizedDescription; status.stringValue = ""; return
        }
        guard sourceItems.allSatisfy(\.allowsPrinting) else {
            spinner.stopAnimation(nil); summary.stringValue = "部分 PDF 不允许打印"
            let names = sourceItems.filter { !$0.allowsPrinting }.map(\.name).joined(separator: "、")
            detail.stringValue = "以下文档设置了打印权限限制：\(names)"
            mode.selectedSegment = 0; changeMode(); return
        }
        let currentRevision = revision
        let sources = sourceItems
        summary.stringValue = "正在生成打印预览…"; detail.stringValue = ""; status.stringValue = ""
        spinner.startAnimation(nil)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            do {
                let result = try Imposition.compose(sources: sources, settings: settings,
                                                     cancelled: { operation.isCancelled })
                guard let result = result, !operation.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self = self, self.revision == currentRevision else { return }
                    self.spinner.stopAnimation(nil)
                    guard let output = PDFDocument(data: result.data) else { self.showError("无法打开生成的打印预览。"); return }
                    self.outputData = result.data; self.outputDocument = output; self.outputSettings = settings
                    let sourceSummary = self.sourceItems.count == 1 ? "1 个 PDF" : "\(self.sourceItems.count) 个 PDF"
                    self.summary.stringValue = "\(sourceSummary) · \(settings.pageIndices.count) 页 → \(result.sheetCount) 个打印面"
                    self.detail.stringValue = "\(settings.paperName) · \(settings.landscape ? "横向" : "纵向") · 每面 \(settings.pagesPerSheet) 页 · \(result.rows) 行 × \(result.columns) 列"
                    self.status.stringValue = "单面打印用 \(result.sheetCount) 张纸；双面选项在系统打印窗口中设置。"
                    self.changeMode(); self.updateAvailability()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.revision == currentRevision else { return }
                    self.spinner.stopAnimation(nil); self.summary.stringValue = "未能生成打印预览"
                    self.detail.stringValue = error.localizedDescription
                }
            }
        }
        renderQueue.addOperation(operation)
    }
    func updateAvailability() {
        printButton.isEnabled = outputDocument != nil
        exportButton.isEnabled = outputDocument != nil
        mode.isEnabled = sourceDocument != nil
        for control in controls { control.isEnabled = sourceDocument != nil }
    }
    @objc func changeMode() {
        pdfView.displayMode = mode.selectedSegment == 0 ? .singlePageContinuous : .singlePage
        pdfView.document = mode.selectedSegment == 0 ? sourceDocument : outputDocument
        pdfView.goToFirstPage(nil)
        pdfView.autoScales = true
        updatePageLabel()
    }
    @objc func updatePageLabel() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { pageLabel.stringValue = ""; return }
        pageLabel.stringValue = "\(document.index(for: page) + 1) / \(document.pageCount)"
    }
    @objc func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc func nextPage() { pdfView.goToNextPage(nil) }
    @objc func fitPage() { pdfView.autoScales = true }
    @objc func zoomIn() { pdfView.zoomIn(nil) }
    @objc func zoomOut() { pdfView.zoomOut(nil) }

    @objc func exportPDF() {
        guard let data = outputData, let settings = outputSettings else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        let name = sourceURLs.count == 1 ? sourceURLs[0].deletingPathExtension().lastPathComponent : "多个PDF"
        panel.nameFieldStringValue = "\(name)-每面\(settings.pagesPerSheet)页.pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if self?.sourceURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) == true {
                self?.showError("请选择其他文件名，以保留原 PDF。"); return
            }
            do { try data.write(to: url, options: .atomic); self?.status.stringValue = "已保存：\(url.lastPathComponent)" }
            catch { self?.showError(error.localizedDescription) }
        }
    }
    @objc func printPDF() {
        guard let document = outputDocument, let settings = outputSettings else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperName = NSPrinter.PaperName(settings.paperName == "Letter" ? "na-letter" : settings.paperName)
        info.orientation = .portrait
        info.paperSize = settings.portraitSize
        info.orientation = settings.landscape ? .landscape : .portrait
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        info.dictionary()[NSPrintInfo.AttributeKey.pagesAcross] = 1
        info.dictionary()[NSPrintInfo.AttributeKey.pagesDown] = 1
        info.dictionary()[NSPrintInfo.AttributeKey.scalingFactor] = 1.0
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false) else {
            showError("无法创建打印任务，请检查打印机设置。"); return
        }
        let jobName = sourceURLs.count == 1 ? sourceURLs[0].deletingPathExtension().lastPathComponent : "\(sourceURLs.count)个PDF"
        operation.jobTitle = "\(jobName) · 每面\(settings.pagesPerSheet)页"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options = [.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsPreview]
        operation.printPanel.jobStyleHint = .noPresets
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
