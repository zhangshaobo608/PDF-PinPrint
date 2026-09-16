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

final class PDFQueueRow: NSView {
    let sourceIndex: Int
    let moveUpButton = NSButton()
    let moveDownButton = NSButton()
    let removeButton = NSButton()
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onRemove: (() -> Void)?

    init(source: PDFSource, index: Int) {
        sourceIndex = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let handle = NSTextField(labelWithString: "⋮⋮")
        handle.font = .systemFont(ofSize: 13, weight: .semibold)
        handle.textColor = .tertiaryLabelColor
        handle.alignment = .center
        handle.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let thumbnail = NSImageView(image: source.thumbnail ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.imageAlignment = .alignCenter
        thumbnail.imageFrameStyle = .photo
        thumbnail.widthAnchor.constraint(equalToConstant: 34).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let name = NSTextField(labelWithString: source.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailKey = source.allowsPrinting ? "queue.ready" : "queue.print_restricted"
        let detail = NSTextField(labelWithString: L10n.format(detailKey, source.pageCount))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = source.allowsPrinting ? .secondaryLabelColor : .systemOrange
        let textStack = NSStackView(views: [name, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(moveUpButton, symbol: "chevron.up", label: L10n.string("queue.move_up"), action: #selector(moveRowUp))
        configureIconButton(moveDownButton, symbol: "chevron.down", label: L10n.string("queue.move_down"), action: #selector(moveRowDown))
        configureIconButton(removeButton, symbol: "xmark", label: L10n.string("queue.remove"), action: #selector(removeRow))
        moveUpButton.isEnabled = index > 0

        let reorder = NSStackView(views: [moveUpButton, moveDownButton])
        reorder.orientation = .vertical
        reorder.spacing = 0

        let row = NSStackView(views: [handle, thumbnail, textStack, reorder, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 58)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureIconButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @objc private func moveRowUp() { onMoveUp?() }
    @objc private func moveRowDown() { onMoveDown?() }
    @objc private func removeRow() { onRemove?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuItemValidation {
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
    let printButton = NSButton(title: L10n.string("button.print"), target: nil, action: nil)
    let exportButton = NSButton(title: L10n.string("button.export"), target: nil, action: nil)
    let spinner = NSProgressIndicator()
    let sourceQueueBox = NSStackView()
    let sourceQueueScroll = NSScrollView()
    let sourceQueueRows = NSStackView()
    let sourceQueueCount = NSTextField(labelWithString: "")
    let sourceQueueTotal = NSTextField(labelWithString: "")
    var sourceQueueHeightConstraint: NSLayoutConstraint!
    var sourceQueueRowsHeightConstraint: NSLayoutConstraint!
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("app.name")
        window.minSize = NSSize(width: 900, height: 760)
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
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 300),
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
        let open = button(L10n.string("button.choose_multiple"), #selector(openPanel))
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        let title = label(L10n.string("app.name"), size: 23, weight: .bold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        let subtitle = label(L10n.string("app.subtitle"), size: 12, weight: .regular)
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.textColor = .secondaryLabelColor
        countField.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        countField.alignment = .center
        countField.delegate = self
        countField.setAccessibilityLabel(L10n.string("accessibility.pages_per_sheet"))
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
        paperPopup.addItems(withTitles: [L10n.string("paper.a4"), L10n.string("paper.a3"), L10n.string("paper.letter")])
        orientation.selectedSegment = 0
        orientation.segmentDistribution = .fillEqually
        arrangement.addItems(withTitles: [L10n.string("arrangement.auto"), L10n.string("arrangement.vertical"), L10n.string("arrangement.horizontal")])
        arrangement.selectItem(at: 1)
        margins.addItems(withTitles: [L10n.string("margin.standard"), L10n.string("margin.narrow"), L10n.string("margin.wide")])
        rangeField.placeholderString = L10n.string("range.placeholder")
        rangeField.delegate = self
        rangeField.setAccessibilityLabel(L10n.string("accessibility.page_range"))
        borderCheckbox.toolTip = L10n.string("border.tooltip")
        for control in [paperPopup, orientation, arrangement, margins, borderCheckbox] as [NSControl] {
            control.target = self; control.action = #selector(settingsChanged)
        }
        controls = [countField, countStepper, paperPopup, orientation, arrangement, margins, borderCheckbox, rangeField]
        let hint = label(L10n.string("hint.pages_per_sheet"), size: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        let countGroup = NSStackView(views: [label(L10n.string("label.pages_per_sheet")), countRow, hint])
        countGroup.orientation = .vertical; countGroup.alignment = .leading; countGroup.spacing = 7

        sourceQueueRows.orientation = .vertical
        sourceQueueRows.alignment = .leading
        sourceQueueRows.distribution = .fill
        sourceQueueRows.spacing = 0
        sourceQueueRows.translatesAutoresizingMaskIntoConstraints = false
        sourceQueueScroll.drawsBackground = false
        sourceQueueScroll.hasVerticalScroller = true
        sourceQueueScroll.hasHorizontalScroller = false
        sourceQueueScroll.autohidesScrollers = true
        sourceQueueScroll.borderType = .noBorder
        sourceQueueScroll.translatesAutoresizingMaskIntoConstraints = false
        sourceQueueScroll.documentView = sourceQueueRows
        sourceQueueHeightConstraint = sourceQueueScroll.heightAnchor.constraint(equalToConstant: 58)
        sourceQueueRowsHeightConstraint = sourceQueueRows.heightAnchor.constraint(equalToConstant: 58)
        NSLayoutConstraint.activate([
            sourceQueueRows.leadingAnchor.constraint(equalTo: sourceQueueScroll.contentView.leadingAnchor),
            sourceQueueRows.trailingAnchor.constraint(equalTo: sourceQueueScroll.contentView.trailingAnchor),
            sourceQueueRows.topAnchor.constraint(equalTo: sourceQueueScroll.contentView.topAnchor),
            sourceQueueHeightConstraint,
            sourceQueueRowsHeightConstraint
        ])
        let queueTitle = label(L10n.string("queue.title"), size: 12, weight: .semibold)
        sourceQueueCount.font = .systemFont(ofSize: 11)
        sourceQueueCount.textColor = .secondaryLabelColor
        sourceQueueTotal.font = .systemFont(ofSize: 11)
        sourceQueueTotal.textColor = .secondaryLabelColor
        let queueHeader = NSStackView(views: [queueTitle, NSView(), sourceQueueCount, sourceQueueTotal])
        queueHeader.orientation = .horizontal
        queueHeader.alignment = .centerY
        queueHeader.spacing = 6
        let addMore = NSButton(title: L10n.string("queue.add_more"), target: self, action: #selector(openPanel))
        addMore.bezelStyle = .inline
        addMore.isBordered = false
        addMore.contentTintColor = .controlAccentColor
        addMore.font = .systemFont(ofSize: 11, weight: .semibold)
        let queueHint = label(L10n.string("queue.reorder_hint"), size: 11, weight: .regular)
        queueHint.textColor = .secondaryLabelColor
        let queueFooter = NSStackView(views: [queueHint, NSView(), addMore])
        queueFooter.orientation = .horizontal
        queueFooter.alignment = .centerY
        queueFooter.spacing = 6
        sourceQueueBox.orientation = .vertical
        sourceQueueBox.alignment = .leading
        sourceQueueBox.distribution = .fill
        sourceQueueBox.spacing = 0
        sourceQueueBox.wantsLayer = true
        sourceQueueBox.layer?.borderWidth = 1
        sourceQueueBox.layer?.borderColor = NSColor.separatorColor.cgColor
        sourceQueueBox.layer?.cornerRadius = 7
        sourceQueueBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        sourceQueueBox.addArrangedSubview(queueHeader)
        sourceQueueBox.addArrangedSubview(sourceQueueScroll)
        sourceQueueBox.addArrangedSubview(queueFooter)
        sourceQueueBox.setContentHuggingPriority(.required, for: .vertical)
        sourceQueueBox.setContentCompressionResistancePriority(.required, for: .vertical)
        sourceQueueBox.isHidden = true
        sourceQueueBox.translatesAutoresizingMaskIntoConstraints = false
        queueHeader.widthAnchor.constraint(equalTo: sourceQueueBox.widthAnchor, constant: -16).isActive = true
        queueFooter.widthAnchor.constraint(equalTo: sourceQueueBox.widthAnchor, constant: -16).isActive = true
        sourceQueueScroll.widthAnchor.constraint(equalTo: sourceQueueBox.widthAnchor).isActive = true
        let stack = NSStackView(views: [title, subtitle, open, sourceQueueBox, countGroup,
            section(L10n.string("section.paper"), paperPopup), section(L10n.string("section.orientation"), orientation),
            section(L10n.string("section.arrangement"), arrangement), section(L10n.string("section.margin"), margins), borderCheckbox, section(L10n.string("section.page_range"), rangeField)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(19, after: subtitle)
        stack.setCustomSpacing(18, after: open)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.hasHorizontalScroller = false
        sidebarScroll.autohidesScrollers = false
        sidebarScroll.scrollerStyle = .legacy
        sidebarScroll.borderType = .noBorder
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        let sidebarDocument = NSView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarDocument
        sidebar.addSubview(sidebarScroll)
        sidebarDocument.addSubview(stack)
        for view in [open, sourceQueueBox, countGroup] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
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
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -18),
            sidebarDocument.leadingAnchor.constraint(equalTo: sidebarScroll.contentView.leadingAnchor),
            sidebarDocument.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
            sidebarDocument.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebarDocument.heightAnchor.constraint(greaterThanOrEqualTo: sidebarScroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: sidebarDocument.topAnchor, constant: 23),
            stack.bottomAnchor.constraint(equalTo: sidebarDocument.bottomAnchor, constant: -23),
            actions.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
        ])
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(changeMode)
        let fit = button(L10n.string("button.fit"), #selector(fitPage))
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
        let bottom = NSStackView(views: [button(L10n.string("button.previous"), #selector(previousPage)), pageLabel,
                                       button(L10n.string("button.next"), #selector(nextPage)), NSView(), spinner])
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
        let emptyTitle = label(L10n.string("empty.title"), size: 25, weight: .semibold)
        let emptyText = label(L10n.string("empty.text"), size: 13, weight: .regular)
        emptyText.textColor = .secondaryLabelColor
        emptyView.setViews([icon, emptyTitle, emptyText, button(L10n.string("button.choose_multiple"), #selector(openPanel))], in: .center)
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
            sourceItems = items; sourceDocument = previewDocument; sourceURLs = orderedURLs
            updateSourceMetadata()
            refreshSourceQueue()
            rangeField.stringValue = ""
            emptyView.isHidden = true
            pdfView.document = previewDocument
            mode.selectedSegment = 1
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

    func refreshSourceQueue() {
        sourceQueueRows.arrangedSubviews.forEach {
            sourceQueueRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let totalPages = sourceItems.reduce(0) { $0 + $1.pageCount }
        sourceQueueCount.stringValue = L10n.format("queue.count", sourceItems.count)
        sourceQueueTotal.stringValue = L10n.format("queue.total_pages", totalPages)
        sourceQueueBox.isHidden = sourceItems.isEmpty
        let queueContentHeight = max(CGFloat(sourceItems.count) * 58, 1)
        sourceQueueRowsHeightConstraint.constant = queueContentHeight
        sourceQueueHeightConstraint.constant = min(queueContentHeight, 232)
        sourceQueueScroll.hasVerticalScroller = queueContentHeight > 232
        for (index, source) in sourceItems.enumerated() {
            let row = PDFQueueRow(source: source, index: index)
            row.onMoveUp = { [weak self] in self?.moveSource(from: index, to: index - 1) }
            row.onMoveDown = { [weak self] in self?.moveSource(from: index, to: index + 1) }
            row.onRemove = { [weak self] in self?.removeSource(at: index) }
            sourceQueueRows.addArrangedSubview(row)
        }
        sourceQueueRows.needsLayout = true
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
            pdfView.document = sourceDocument
            mode.selectedSegment = 1
            regenerate()
        } catch { showError(error.localizedDescription) }
    }

    func moveSource(from index: Int, to destination: Int) {
        guard sourceItems.indices.contains(index), sourceItems.indices.contains(destination), index != destination else { return }
        sourceItems.swapAt(index, destination)
        sourceURLs.swapAt(index, destination)
        applySourceOrderChange()
    }

    func removeSource(at index: Int) {
        guard sourceItems.indices.contains(index) else { return }
        sourceItems.remove(at: index)
        sourceURLs.remove(at: index)
        guard !sourceItems.isEmpty else {
            sourceDocument = nil
            sourceTitle.stringValue = L10n.string("source.no_pdf")
            sourceDetail.stringValue = L10n.string("source.local_only")
            sourceQueueBox.isHidden = true
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
            spinner.stopAnimation(nil); summary.stringValue = L10n.string("summary.check_settings")
            detail.stringValue = error.localizedDescription; status.stringValue = ""; return
        }
        guard sourceItems.allSatisfy(\.allowsPrinting) else {
            spinner.stopAnimation(nil); summary.stringValue = L10n.string("summary.print_restricted")
            let names = sourceItems.filter { !$0.allowsPrinting }.map(\.name).joined(separator: L10n.string("list.separator"))
            detail.stringValue = L10n.format("detail.print_restricted", names)
            mode.selectedSegment = 0; changeMode(); return
        }
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
                    self.spinner.stopAnimation(nil)
                    guard let output = PDFDocument(data: result.data) else { self.showError(L10n.string("error.preview_open")); return }
                    self.outputData = result.data; self.outputDocument = output; self.outputSettings = settings
                    let sourceSummary = self.sourceItems.count == 1 ? L10n.string("summary.one_pdf") : L10n.format("summary.multiple_pdfs", self.sourceItems.count)
                    self.summary.stringValue = L10n.format("summary.result", sourceSummary, settings.pageIndices.count, result.sheetCount)
                    let orientation = L10n.string(settings.landscape ? "orientation.landscape" : "orientation.portrait")
                    self.detail.stringValue = L10n.format("detail.result", settings.paperName, orientation, settings.pagesPerSheet, result.rows, result.columns)
                    self.status.stringValue = L10n.format("status.print_sheets", result.sheetCount)
                    self.changeMode(); self.updateAvailability()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.revision == currentRevision else { return }
                    self.spinner.stopAnimation(nil); self.summary.stringValue = L10n.string("summary.failed")
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
