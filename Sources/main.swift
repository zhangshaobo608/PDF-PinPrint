import AppKit
import PDFKit
import UniformTypeIdentifiers

enum L10n {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}

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

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation {
    var window: NSWindow!
    var appIcon: NSImage?
    let pdfView = PDFView()
    let thumbnailView = PDFThumbnailView()
    let sourceTitle = NSTextField(labelWithString: L10n.string("source.no_pdf"))
    let sourceDetail = NSTextField(labelWithString: L10n.string("source.local_only"))
    let countField = NSTextField(string: "3")
    let countStepper = NSStepper()
    let paperPopup = NSPopUpButton()
    let orientation = NSSegmentedControl(labels: [L10n.string("orientation.portrait"), L10n.string("orientation.landscape")], trackingMode: .selectOne, target: nil, action: nil)
    let arrangement = NSPopUpButton()
    let margins = NSPopUpButton()
    let borderCheckbox = NSButton(checkboxWithTitle: L10n.string("border.show"), target: nil, action: nil)
    let rangeField = NSTextField(string: "")
    let mode = NSSegmentedControl(labels: [L10n.string("mode.original"), L10n.string("mode.preview")], trackingMode: .selectOne, target: nil, action: nil)
    let summary = NSTextField(wrappingLabelWithString: L10n.string("summary.ready"))
    let detail = NSTextField(wrappingLabelWithString: L10n.string("detail.default"))
    let status = NSTextField(labelWithString: "")
    let pageLabel = NSTextField(labelWithString: "")
    let emptyView = NSStackView()
    let spinner = NSProgressIndicator()
    let sourceQueueBox = NSStackView()
    let sourceList = PDFSourceList()
    let sourceQueueCount = NSTextField(labelWithString: "")
    let queueDisclosure = NSButton()
    let queueHint = NSTextField(labelWithString: L10n.string("queue.reorder_hint"))
    var sourceQueueHeightConstraint: NSLayoutConstraint!
    let splitController = NSSplitViewController()
    var sidebarItem: NSSplitViewItem!
    let previewContent = NSView()
    let renderingBadge = NSVisualEffectView()
    let renderingLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    var displayedPreview: PDFDocument?
    var isRendering = false
    var queueCollapsed = false
    var savedPreviewPage = 0
    var savedPreviewScale: CGFloat?
    let preferences = UserDefaults.standard
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
        let aboutItem = appMenu.addItem(withTitle: L10n.string("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.string("menu.file"))
        for (title, action, key) in [(L10n.string("menu.choose_pdf"), #selector(openPanel), "o"),
                                     (L10n.string("menu.export_pdf"), #selector(exportPDF), "s"),
                                     (L10n.string("menu.print"), #selector(printPDF), "p")] {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.string("menu.edit"))
        editMenu.addItem(withTitle: L10n.string("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.string("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.string("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.string("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.string("menu.view"))
        let sidebarCommand = viewMenu.addItem(withTitle: L10n.string("toolbar.sidebar"), action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebarCommand.keyEquivalentModifierMask = [.command, .option]; sidebarCommand.target = self
        viewMenu.addItem(.separator())
        for (key, action, shortcut) in [("mode.original", #selector(showOriginal), "1"), ("mode.preview", #selector(showPrintPreview), "2"),
                                       ("toolbar.zoom_in", #selector(zoomIn), "+"), ("toolbar.zoom_out", #selector(zoomOut), "-"),
                                       ("button.fit", #selector(fitPage), "0")] {
            let item = viewMenu.addItem(withTitle: L10n.string(key), action: action, keyEquivalent: shortcut)
            item.target = self
        }
        viewMenu.addItem(.separator())
        for (key, action, shortcut) in [("button.previous", #selector(previousPage), "["), ("button.next", #selector(nextPage), "]")] {
            let item = viewMenu.addItem(withTitle: L10n.string(key), action: action, keyEquivalent: shortcut)
            item.target = self; item.keyEquivalentModifierMask = [.command]
        }
        viewItem.submenu = viewMenu; menu.addItem(viewItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.string("menu.window"))
        windowMenu.addItem(withTitle: L10n.string("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.string("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; menu.addItem(windowItem); NSApp.windowsMenu = windowMenu
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.string("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
    }

    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = appIcon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showOriginal) { item.state = mode.selectedSegment == 0 ? .on : .off }
        if item.action == #selector(showPrintPreview) { item.state = mode.selectedSegment == 1 ? .on : .off }
        if item.action == #selector(toggleSidebar) { item.state = sidebarItem?.isCollapsed == false ? .on : .off }
        return canPerform(item.action)
    }

    func canPerform(_ action: Selector?) -> Bool {
        switch action {
        case #selector(printPDF), #selector(exportPDF): return outputDocument != nil
        case #selector(showOriginal), #selector(showPrintPreview), #selector(toggleSidebar): return sourceDocument != nil
        case #selector(zoomIn), #selector(zoomOut), #selector(fitPage): return pdfView.document != nil
        case #selector(previousPage): return pdfView.canGoToPreviousPage
        case #selector(nextPage): return pdfView.canGoToNextPage
        default: return true
        }
    }

    func makeToolbar() {
        let toolbar = NSToolbar(identifier: "PDFMergePrint.Toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("sidebar"), NSToolbarItem.Identifier("add"), .flexibleSpace,
         NSToolbarItem.Identifier("mode"), .flexibleSpace, NSToolbarItem.Identifier("zoomOut"),
         NSToolbarItem.Identifier("zoomIn"), NSToolbarItem.Identifier("fit"), NSToolbarItem.Identifier("export"), NSToolbarItem.Identifier("print")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier.rawValue == "mode" {
            item.view = mode; item.label = L10n.string("toolbar.mode")
            let menu = NSMenu()
            for (key, action) in [("mode.original", #selector(showOriginal)), ("mode.preview", #selector(showPrintPreview))] {
                let entry = menu.addItem(withTitle: L10n.string(key), action: action, keyEquivalent: ""); entry.target = self
            }
            let representation = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            representation.submenu = menu; item.menuFormRepresentation = representation
            return item
        }
        let config: (String, String, Selector)
        switch identifier.rawValue {
        case "sidebar": config = ("toolbar.sidebar", "sidebar.left", #selector(toggleSidebar))
        case "add": config = ("toolbar.add", "doc.badge.plus", #selector(openPanel))
        case "zoomOut": config = ("toolbar.zoom_out", "minus.magnifyingglass", #selector(zoomOut))
        case "zoomIn": config = ("toolbar.zoom_in", "plus.magnifyingglass", #selector(zoomIn))
        case "fit": config = ("button.fit", "arrow.up.left.and.arrow.down.right", #selector(fitPage))
        case "export": config = ("toolbar.export", "square.and.arrow.up", #selector(exportPDF))
        case "print": config = ("button.print", "printer", #selector(printPDF))
        default: return nil
        }
        item.label = L10n.string(config.0); item.toolTip = item.label
        item.image = NSImage(systemSymbolName: config.1, accessibilityDescription: item.label)
        item.target = self; item.action = config.2
        item.visibilityPriority = identifier.rawValue == "print" ? .high : .standard
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { canPerform(item.action) }

    @objc func toggleSidebar() {
        sidebarItem.isCollapsed.toggle()
        preferences.set(sidebarItem.isCollapsed, forKey: "sidebarCollapsed")
    }
    @objc func toggleQueue() {
        queueCollapsed.toggle(); sourceList.isHidden = queueCollapsed
        queueHint.isHidden = queueCollapsed
        queueDisclosure.image = NSImage(systemSymbolName: queueCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        queueDisclosure.setAccessibilityValue(L10n.string(queueCollapsed ? "queue.collapsed" : "queue.expanded"))
    }
    @objc func showOriginal() { mode.selectedSegment = 0; changeMode() }
    @objc func showPrintPreview() { mode.selectedSegment = 1; changeMode() }

    func restoreSettings() {
        let saved = preferences.dictionary(forKey: "printSettings") ?? [:]
        let count = saved["count"] as? Int ?? 3
        countField.integerValue = (1...16).contains(count) ? count : 3
        countStepper.integerValue = countField.integerValue
        paperPopup.selectItem(at: min(max(saved["paper"] as? Int ?? 0, 0), 2))
        orientation.selectedSegment = saved["landscape"] as? Bool == true ? 1 : 0
        arrangement.selectItem(at: min(max(saved["arrangement"] as? Int ?? 1, 0), 2))
        margins.selectItem(at: min(max(saved["margin"] as? Int ?? 0, 0), 2))
        borderCheckbox.state = saved["borders"] as? Bool == true ? .on : .off
    }

    func saveSettings() {
        preferences.set(["count": countField.integerValue, "paper": paperPopup.indexOfSelectedItem,
            "landscape": orientation.selectedSegment == 1, "arrangement": arrangement.indexOfSelectedItem,
            "margin": margins.indexOfSelectedItem, "borders": borderCheckbox.state == .on], forKey: "printSettings")
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
        window.title = L10n.string("app.name")
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        window.toolbarStyle = .unified

        let root = DropView()
        root.onDrop = { [weak self] urls in self?.openPDFs(urls) }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        let sidebarController = NSViewController()
        sidebarController.view = sidebar
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let rightController = NSViewController()
        rightController.view = root
        let rightItem = NSSplitViewItem(viewController: rightController)
        rightItem.minimumThickness = 360
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(rightItem)
        splitController.splitView.autosaveName = "PDFMergePrint.Sidebar"
        window.contentViewController = splitController
        sidebarItem.isCollapsed = true
        buildSidebar(in: sidebar)
        buildPreview(in: root)
        makeToolbar()
        window.setFrameAutosaveName("PDFMergePrint.MainWindow")
        if !window.setFrameUsingName("PDFMergePrint.MainWindow") {
            window.setContentSize(NSSize(width: 1120, height: 780))
            window.center()
        }
        updateAvailability()
    }

    func group(_ title: String, views: [NSView]) -> NSStackView {
        let heading = label(title, size: 13, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(14, after: heading)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    func buildSidebar(in sidebar: NSView) {
        countField.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        countField.alignment = .center
        countField.delegate = self
        countField.setAccessibilityLabel(L10n.string("accessibility.pages_per_sheet"))
        countField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        countStepper.minValue = 1; countStepper.maxValue = 16; countStepper.increment = 1
        countStepper.target = self; countStepper.action = #selector(stepCount)
        countStepper.setAccessibilityLabel(L10n.string("accessibility.pages_per_sheet"))
        let countRow = NSStackView(views: [countField, countStepper])
        countRow.spacing = 8
        countField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paperPopup.addItems(withTitles: [L10n.string("paper.a4"), L10n.string("paper.a3"), L10n.string("paper.letter")])
        orientation.segmentDistribution = .fillEqually
        arrangement.addItems(withTitles: [L10n.string("arrangement.auto"), L10n.string("arrangement.vertical"), L10n.string("arrangement.horizontal")])
        margins.addItems(withTitles: [L10n.string("margin.standard"), L10n.string("margin.narrow"), L10n.string("margin.wide")])
        rangeField.placeholderString = L10n.string("range.placeholder")
        rangeField.delegate = self
        rangeField.setAccessibilityLabel(L10n.string("accessibility.page_range"))
        borderCheckbox.toolTip = L10n.string("border.tooltip")
        borderCheckbox.setAccessibilityLabel(L10n.string("border.show"))
        for (control, key) in [(paperPopup, "section.paper"), (arrangement, "section.arrangement"), (margins, "section.margin")] {
            control.setAccessibilityLabel(L10n.string(key))
        }
        for control in [paperPopup, orientation, arrangement, margins, borderCheckbox] as [NSControl] {
            control.target = self; control.action = #selector(settingsChanged)
        }
        controls = [countField, countStepper, paperPopup, orientation, arrangement, margins, borderCheckbox, rangeField]
        restoreSettings()
        let hint = label(L10n.string("hint.pages_per_sheet"), size: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        let countGroup = section(L10n.string("label.pages_per_sheet"), countRow)
        countGroup.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: countGroup.widthAnchor).isActive = true

        queueDisclosure.title = L10n.string("queue.title")
        queueDisclosure.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        queueDisclosure.imagePosition = .imageLeading
        queueDisclosure.isBordered = false
        queueDisclosure.font = .systemFont(ofSize: 13, weight: .semibold)
        queueDisclosure.target = self; queueDisclosure.action = #selector(toggleQueue)
        queueDisclosure.setAccessibilityLabel(L10n.string("queue.toggle"))
        queueDisclosure.toolTip = L10n.string("queue.toggle")
        queueDisclosure.heightAnchor.constraint(equalToConstant: 28).isActive = true
        sourceQueueCount.font = .systemFont(ofSize: 11)
        sourceQueueCount.textColor = .secondaryLabelColor
        let header = NSStackView(views: [queueDisclosure, NSView(), sourceQueueCount])
        sourceList.onRemove = { [weak self] index in self?.removeSource(at: index) }
        sourceList.onMove = { [weak self] from, to in self?.moveSource(from: from, to: to) }
        sourceList.onDropFiles = { [weak self] urls in self?.openPDFs(urls) }
        sourceQueueHeightConstraint = sourceList.heightAnchor.constraint(equalToConstant: 116)
        sourceQueueHeightConstraint.isActive = true
        queueHint.font = .systemFont(ofSize: 11)
        queueHint.textColor = .secondaryLabelColor
        sourceQueueBox.setViews([header, sourceList, queueHint], in: .top)
        sourceQueueBox.orientation = .vertical; sourceQueueBox.alignment = .leading; sourceQueueBox.spacing = 6
        for view in [header, sourceList, queueHint] { view.widthAnchor.constraint(equalTo: sourceQueueBox.widthAnchor).isActive = true }

        let layout = group(L10n.string("group.layout"), views: [countGroup,
            section(L10n.string("section.orientation"), orientation), section(L10n.string("section.arrangement"), arrangement)])
        let paper = group(L10n.string("group.paper"), views: [section(L10n.string("section.paper"), paperPopup),
            section(L10n.string("section.margin"), margins), borderCheckbox])
        let range = group(L10n.string("group.range"), views: [section(L10n.string("section.page_range"), rangeField)])
        let stack = NSStackView(views: [sourceQueueBox, separator(), layout, separator(), paper, separator(), range])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.distribution = .fill; stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(stack); sidebar.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor), scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }

    func separator() -> NSBox {
        let line = NSBox(); line.boxType = .separator; return line
    }

    func buildPreview(in right: NSView) {
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(changeMode)
        mode.setAccessibilityLabel(L10n.string("toolbar.mode"))
        previewContent.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(previewContent)
        NSLayoutConstraint.activate([
            previewContent.leadingAnchor.constraint(equalTo: right.leadingAnchor), previewContent.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            previewContent.topAnchor.constraint(equalTo: right.topAnchor), previewContent.bottomAnchor.constraint(equalTo: right.bottomAnchor)
        ])
        pdfView.autoScales = true; pdfView.displayMode = .singlePage; pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true; pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 54, height: 74)
        thumbnailView.backgroundColor = .windowBackgroundColor
        thumbnailView.setAccessibilityLabel(L10n.string("preview.thumbnails"))
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(pdfView); previewContent.addSubview(thumbnailView)
        for (control, symbol, key, action) in [(previousButton, "chevron.left", "button.previous", #selector(previousPage)), (nextButton, "chevron.right", "button.next", #selector(nextPage))] {
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.string(key))
            control.bezelStyle = .texturedRounded; control.target = self; control.action = action
            control.toolTip = L10n.string(key); control.setAccessibilityLabel(L10n.string(key))
            control.widthAnchor.constraint(equalToConstant: 32).isActive = true
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let bottom = NSStackView(views: [previousButton, pageLabel, nextButton, NSView()])
        bottom.spacing = 10; bottom.translatesAutoresizingMaskIntoConstraints = false
        summary.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let info = NSStackView(views: [summary, detail, status])
        info.orientation = .vertical; info.alignment = .leading; info.spacing = 3
        info.translatesAutoresizingMaskIntoConstraints = false
        for field in [summary, detail, status] { field.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true }
        previewContent.addSubview(bottom); previewContent.addSubview(info)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor), thumbnailView.widthAnchor.constraint(equalToConstant: 76),
            thumbnailView.topAnchor.constraint(equalTo: previewContent.topAnchor), thumbnailView.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            pdfView.topAnchor.constraint(equalTo: previewContent.topAnchor), pdfView.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor), pdfView.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor, constant: 18), bottom.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -8), bottom.heightAnchor.constraint(equalToConstant: 28),
            info.leadingAnchor.constraint(equalTo: bottom.leadingAnchor), info.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            info.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor, constant: -12)
        ])
        renderingBadge.material = .popover; renderingBadge.blendingMode = .withinWindow
        renderingBadge.wantsLayer = true; renderingBadge.layer?.cornerRadius = 9
        renderingBadge.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        renderingLabel.font = .systemFont(ofSize: 12)
        let progress = NSStackView(views: [spinner, renderingLabel])
        progress.spacing = 8; progress.translatesAutoresizingMaskIntoConstraints = false
        renderingBadge.addSubview(progress); previewContent.addSubview(renderingBadge)
        NSLayoutConstraint.activate([
            renderingBadge.topAnchor.constraint(equalTo: pdfView.topAnchor, constant: 12),
            renderingBadge.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor, constant: -12),
            progress.leadingAnchor.constraint(equalTo: renderingBadge.leadingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: renderingBadge.trailingAnchor, constant: -12),
            progress.topAnchor.constraint(equalTo: renderingBadge.topAnchor, constant: 9),
            progress.bottomAnchor.constraint(equalTo: renderingBadge.bottomAnchor, constant: -9)
        ])
        renderingBadge.isHidden = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!)
        icon.setAccessibilityElement(false)
        icon.setAccessibilityHidden(true)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        let emptyTitle = NSTextField(wrappingLabelWithString: L10n.string("empty.title"))
        emptyTitle.font = .systemFont(ofSize: 25, weight: .semibold); emptyTitle.alignment = .center
        let emptyText = NSTextField(wrappingLabelWithString: L10n.string("empty.text"))
        emptyText.font = .systemFont(ofSize: 13); emptyText.textColor = .secondaryLabelColor; emptyText.alignment = .center
        emptyView.setViews([icon, emptyTitle, emptyText, button(L10n.string("button.choose_multiple"), #selector(openPanel))], in: .center)
        emptyView.orientation = .vertical; emptyView.spacing = 18; emptyView.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(emptyView)
        let emptyWidth = emptyView.widthAnchor.constraint(equalToConstant: 460)
        emptyWidth.priority = .defaultHigh; emptyWidth.isActive = true
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: right.centerXAnchor), emptyView.centerYAnchor.constraint(equalTo: right.centerYAnchor, constant: -20),
            emptyView.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: right.leadingAnchor, constant: 32),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor, constant: -32),
            emptyTitle.widthAnchor.constraint(equalTo: emptyView.widthAnchor), emptyText.widthAnchor.constraint(equalTo: emptyView.widthAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(updatePageLabel), name: .PDFViewPageChanged, object: pdfView)
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = L10n.string("open_panel.message")
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, !panel.urls.isEmpty { self?.openPDFs(panel.urls) }
        }
    }
    func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = L10n.string("error.title"); alert.informativeText = message
        alert.addButton(withTitle: L10n.string("button.ok"))
        alert.beginSheetModal(for: window)
    }
    func openPDFs(_ urls: [URL]) {
        do {
            let incomingURLs = Array(Set(urls.map(\.standardizedFileURL)))
            let orderedURLs: [URL]
            if sourceURLs.isEmpty {
                orderedURLs = incomingURLs.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            } else {
                let additions = incomingURLs.filter { !sourceURLs.contains($0) }.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                orderedURLs = sourceURLs + additions
            }
            guard !orderedURLs.isEmpty else { return }
            var items: [PDFSource] = []
            let previewDocument = PDFDocument()
            for url in orderedURLs {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let document = PDFDocument(data: data) else {
                    throw LayoutError.message(L10n.format("error.invalid_pdf", url.lastPathComponent))
                }
                var password: String?
                if document.isLocked {
                    let alert = NSAlert(); alert.messageText = L10n.string("password.title"); alert.informativeText = url.lastPathComponent
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    alert.accessoryView = field; alert.addButton(withTitle: L10n.string("button.open")); alert.addButton(withTitle: L10n.string("button.cancel"))
                    alert.window.initialFirstResponder = field
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    password = field.stringValue
                    guard document.unlock(withPassword: password!) else {
                        throw LayoutError.message(L10n.format("error.wrong_password", url.lastPathComponent))
                    }
                }
                guard document.pageCount > 0 else {
                    throw LayoutError.message(L10n.format("error.empty_pdf", url.lastPathComponent))
                }
                let thumbnail = document.page(at: 0)?.thumbnail(of: NSSize(width: 44, height: 54), for: .cropBox)
                items.append(PDFSource(data: data, password: password, name: url.lastPathComponent,
                                       pageCount: document.pageCount, allowsPrinting: document.allowsPrinting,
                                       thumbnail: thumbnail))
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex), let copy = page.copy() as? PDFPage else {
                        throw LayoutError.message(L10n.format("error.read_page", url.lastPathComponent, pageIndex + 1))
                    }
                    previewDocument.insert(copy, at: previewDocument.pageCount)
                }
            }
            let wasEmpty = sourceItems.isEmpty
            sourceItems = items; sourceDocument = previewDocument; sourceURLs = orderedURLs
            if wasEmpty { sidebarItem.isCollapsed = preferences.bool(forKey: "sidebarCollapsed") }
            updateSourceMetadata()
            refreshSourceQueue()
            rangeField.stringValue = ""
            emptyView.isHidden = true
            if mode.selectedSegment == 0 { pdfView.document = previewDocument }
            regenerate()
        } catch { showError(error.localizedDescription) }
    }

    func updateSourceMetadata() {
        guard !sourceItems.isEmpty, let document = sourceDocument else { return }
        if sourceItems.count == 1 {
            sourceTitle.stringValue = sourceItems[0].name
            sourceDetail.stringValue = L10n.format("source.single_detail", document.pageCount)
            window.title = L10n.format("window.single_title", sourceItems[0].name)
            window.representedURL = sourceURLs.first
        } else {
            sourceTitle.stringValue = L10n.format("source.multiple_title", sourceItems.count)
            sourceDetail.stringValue = L10n.format("source.multiple_detail", document.pageCount)
            window.title = L10n.format("window.multiple_title", sourceItems.count)
            window.representedURL = nil
        }
        sourceTitle.toolTip = sourceURLs.map(\.path).joined(separator: "\n")
    }

    func refreshSourceQueue(selectedIndex: Int? = nil) {
        let totalPages = sourceItems.reduce(0) { $0 + $1.pageCount }
        sourceQueueCount.stringValue = L10n.format("queue.summary", sourceItems.count, totalPages)
        sourceQueueHeightConstraint.constant = min(max(CGFloat(sourceItems.count) * 64 + 16, 80), 208)
        sourceList.update(sources: sourceItems, selectedIndex: selectedIndex)
    }

    func makePreviewDocument() throws -> PDFDocument {
        let previewDocument = PDFDocument()
        for source in sourceItems {
            guard let document = PDFDocument(data: source.data) else {
                throw LayoutError.message(L10n.format("error.read_pdf", source.name))
            }
            if document.isLocked, !document.unlock(withPassword: source.password ?? "") {
                throw LayoutError.message(L10n.format("error.wrong_password", source.name))
            }
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex), let copy = page.copy() as? PDFPage else {
                    throw LayoutError.message(L10n.format("error.read_page", source.name, pageIndex + 1))
                }
                previewDocument.insert(copy, at: previewDocument.pageCount)
            }
        }
        return previewDocument
    }

    func applySourceOrderChange() {
        do {
            sourceDocument = try makePreviewDocument()
            updateSourceMetadata()
            refreshSourceQueue()
            emptyView.isHidden = !sourceItems.isEmpty
            if mode.selectedSegment == 0 { pdfView.document = sourceDocument }
            regenerate()
        } catch { showError(error.localizedDescription) }
    }

    func moveSource(from index: Int, to destination: Int) {
        guard sourceItems.indices.contains(index), sourceItems.indices.contains(destination), index != destination else { return }
        sourceItems.insert(sourceItems.remove(at: index), at: destination)
        sourceURLs.insert(sourceURLs.remove(at: index), at: destination)
        applySourceOrderChange()
        refreshSourceQueue(selectedIndex: destination)
    }

    func removeSource(at index: Int) {
        guard sourceItems.indices.contains(index) else { return }
        sourceItems.remove(at: index)
        sourceURLs.remove(at: index)
        guard !sourceItems.isEmpty else {
            sourceDocument = nil
            sourceTitle.stringValue = L10n.string("source.no_pdf")
            sourceDetail.stringValue = L10n.string("source.local_only")
            refreshSourceQueue()
            displayedPreview = nil
            savedPreviewPage = 0; savedPreviewScale = nil
            window.makeFirstResponder(nil)
            sidebarItem.isCollapsed = true
            pendingRender?.cancel()
            emptyView.isHidden = false
            pdfView.document = nil
            pageLabel.stringValue = ""
            window.title = L10n.string("app.name")
            window.representedURL = nil
            rangeField.stringValue = ""
            invalidateOutput()
            summary.stringValue = L10n.string("summary.ready")
            detail.stringValue = L10n.string("detail.default")
            status.stringValue = ""
            updateAvailability()
            return
        }
        applySourceOrderChange()
        refreshSourceQueue(selectedIndex: min(index, sourceItems.count - 1))
    }

    func readSettings() throws -> PrintSettings {
        guard let n = Int(countField.stringValue.trimmingCharacters(in: .whitespaces)), (1...16).contains(n) else {
            throw LayoutError.message(L10n.string("error.pages_per_sheet"))
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
        if mode.selectedSegment == 1, let document = pdfView.document, let page = pdfView.currentPage {
            savedPreviewPage = document.index(for: page)
            savedPreviewScale = pdfView.autoScales ? nil : pdfView.scaleFactor
        }
        isRendering = !sourceItems.isEmpty
        if isRendering { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        renderingLabel.stringValue = L10n.string("summary.generating")
        updateAvailability()
    }
    func regenerate() {
        pendingRender?.cancel()
        invalidateOutput()
        guard !sourceItems.isEmpty else { return }
        let settings: PrintSettings
        do { settings = try readSettings() }
        catch {
            isRendering = false; spinner.stopAnimation(nil)
            renderingLabel.stringValue = L10n.string("preview.previous")
            summary.stringValue = L10n.string("summary.check_settings")
            detail.stringValue = error.localizedDescription; status.stringValue = ""
            updateAvailability(); return
        }
        guard sourceItems.allSatisfy(\.allowsPrinting) else {
            isRendering = false; spinner.stopAnimation(nil); summary.stringValue = L10n.string("summary.print_restricted")
            let names = sourceItems.filter { !$0.allowsPrinting }.map(\.name).joined(separator: L10n.string("list.separator"))
            detail.stringValue = L10n.format("detail.print_restricted", names)
            displayedPreview = nil
            renderingLabel.stringValue = L10n.string("summary.print_restricted")
            mode.selectedSegment = 0; changeMode(); return
        }
        saveSettings()
        let currentRevision = revision
        let sources = sourceItems
        summary.stringValue = L10n.string("summary.generating"); detail.stringValue = ""; status.stringValue = ""
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
                    self.isRendering = false; self.spinner.stopAnimation(nil)
                    guard let output = PDFDocument(data: result.data) else {
                        self.renderingLabel.stringValue = L10n.string("preview.previous")
                        self.updateAvailability(); self.showError(L10n.string("error.preview_open")); return
                    }
                    self.outputData = result.data; self.outputDocument = output; self.outputSettings = settings
                    let sourceSummary = self.sourceItems.count == 1 ? L10n.string("summary.one_pdf") : L10n.format("summary.multiple_pdfs", self.sourceItems.count)
                    self.summary.stringValue = L10n.format("summary.result", sourceSummary, settings.pageIndices.count, result.sheetCount)
                    let orientation = L10n.string(settings.landscape ? "orientation.landscape" : "orientation.portrait")
                    self.detail.stringValue = L10n.format("detail.result", settings.paperName, orientation, settings.pagesPerSheet, result.rows, result.columns)
                    self.status.stringValue = L10n.format("status.print_sheets", result.sheetCount)
                    self.displayedPreview = output
                    if self.mode.selectedSegment == 1 { self.installPreview(output) }
                    self.updateAvailability()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.revision == currentRevision else { return }
                    self.isRendering = false; self.spinner.stopAnimation(nil)
                    self.renderingLabel.stringValue = L10n.string("preview.previous")
                    self.summary.stringValue = L10n.string("summary.failed")
                    self.detail.stringValue = error.localizedDescription
                    self.updateAvailability()
                }
            }
        }
        renderQueue.addOperation(operation)
    }
    func updateAvailability() {
        let hasSource = sourceDocument != nil
        previewContent.isHidden = !hasSource
        emptyView.isHidden = hasSource
        mode.isEnabled = hasSource
        for control in controls { control.isEnabled = hasSource }
        renderingBadge.isHidden = !hasSource || mode.selectedSegment == 0 || (outputDocument != nil && !isRendering)
        updatePageLabel()
        window?.toolbar?.validateVisibleItems()
    }

    func installPreview(_ document: PDFDocument) {
        pdfView.displayMode = .singlePage
        pdfView.document = document
        if let page = document.page(at: min(savedPreviewPage, max(document.pageCount - 1, 0))) { pdfView.go(to: page) }
        if let scale = savedPreviewScale { pdfView.autoScales = false; pdfView.scaleFactor = scale }
        else { pdfView.autoScales = true }
        updatePageLabel()
    }

    @objc func changeMode() {
        if mode.selectedSegment == 0 {
            if pdfView.document === displayedPreview, let document = pdfView.document, let page = pdfView.currentPage {
                savedPreviewPage = document.index(for: page)
                savedPreviewScale = pdfView.autoScales ? nil : pdfView.scaleFactor
            }
            pdfView.displayMode = .singlePageContinuous
            pdfView.document = sourceDocument
            pdfView.autoScales = true
        } else if let preview = outputDocument ?? displayedPreview { installPreview(preview) }
        else { pdfView.document = nil }
        updateAvailability()
    }
    @objc func updatePageLabel() {
        previousButton.isEnabled = pdfView.canGoToPreviousPage
        nextButton.isEnabled = pdfView.canGoToNextPage
        guard let document = pdfView.document, let page = pdfView.currentPage else { pageLabel.stringValue = ""; return }
        pageLabel.stringValue = "\(document.index(for: page) + 1) / \(document.pageCount)"
        pageLabel.setAccessibilityLabel(L10n.format("preview.page", document.index(for: page) + 1, document.pageCount))
    }
    @objc func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc func nextPage() { pdfView.goToNextPage(nil) }
    @objc func fitPage() { pdfView.autoScales = true }
    @objc func zoomIn() { pdfView.zoomIn(nil) }
    @objc func zoomOut() { pdfView.zoomOut(nil) }

    @objc func exportPDF() {
        guard let data = outputData, let settings = outputSettings else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        let name = sourceURLs.count == 1 ? sourceURLs[0].deletingPathExtension().lastPathComponent : L10n.string("export.multiple_name")
        panel.nameFieldStringValue = L10n.format("export.filename", name, settings.pagesPerSheet)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if self?.sourceURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) == true {
                self?.showError(L10n.string("error.export_same_file")); return
            }
            do { try data.write(to: url, options: .atomic); self?.status.stringValue = L10n.format("status.saved", url.lastPathComponent) }
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
            showError(L10n.string("error.print_setup")); return
        }
        let jobName = sourceURLs.count == 1 ? sourceURLs[0].deletingPathExtension().lastPathComponent : L10n.format("print.multiple_name", sourceURLs.count)
        operation.jobTitle = L10n.format("print.job_title", jobName, settings.pagesPerSheet)
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
