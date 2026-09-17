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

struct SourceQueueState {
    var items: [PDFSource]
    var urls: [URL]
    var selectedIndex: Int
    var pageRange: String
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
    let presetCounts = [1, 2, 3, 4, 5, 6]
    let countPresets = NSSegmentedControl(labels: ["1", "2", "3", "4", "5", "6"], trackingMode: .selectOne, target: nil, action: nil)
    let printButton = NSButton()
    let layoutPresetPopup = NSPopUpButton()
    let presetStore = PrintPresetStore()
    var selectedPresetID: UUID?
    let queueUndoManager = UndoManager()
    let moreSettingsButton = NSButton()
    let moreSettingsContent = NSStackView()
    let moreSettingsHint = NSTextField(wrappingLabelWithString: "")
    var moreSettingsExpanded = false
    let printHelpButton = NSButton()
    var printHelpText = ""
    var printHelpPopover: NSPopover?
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
        queueUndoManager.groupsByEvent = false
        queueUndoManager.levelsOfUndo = 30
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
        let undoItem = editMenu.addItem(withTitle: L10n.string("menu.undo"), action: #selector(undoChange), keyEquivalent: "z")
        undoItem.target = self
        let redoItem = editMenu.addItem(withTitle: L10n.string("menu.redo"), action: #selector(redoChange), keyEquivalent: "z")
        redoItem.target = self; redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
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
        if item.action == #selector(undoChange) || item.action == #selector(redoChange) {
            let isUndo = item.action == #selector(undoChange)
            let manager = activeUndoManager
            let name = isUndo ? manager?.undoActionName : manager?.redoActionName
            let key = isUndo ? "menu.undo" : "menu.redo"
            item.title = name?.isEmpty == false ? L10n.format(key + "_action", name!) : L10n.string(key)
            return (isUndo ? manager?.canUndo : manager?.canRedo) == true
        }
        if item.action == #selector(showOriginal) { item.state = mode.selectedSegment == 0 ? .on : .off }
        if item.action == #selector(showPrintPreview) { item.state = mode.selectedSegment == 1 ? .on : .off }
        if item.action == #selector(toggleSidebar) { item.state = sidebarItem?.isCollapsed == false ? .on : .off }
        return canPerform(item.action)
    }

    // Keep text editing history separate from file queue history.
    var activeUndoManager: UndoManager? {
        let activeWindow = NSApp.keyWindow ?? window
        if let editor = activeWindow?.firstResponder as? NSTextView, editor.isEditable {
            return editor.undoManager
        }
        return activeWindow === window && window.attachedSheet == nil ? queueUndoManager : nil
    }

    @objc func undoChange() { activeUndoManager?.undo() }
    @objc func redoChange() { activeUndoManager?.redo() }

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
         NSToolbarItem.Identifier("zoomIn"), NSToolbarItem.Identifier("fit"), .space, NSToolbarItem.Identifier("export"), NSToolbarItem.Identifier("print")]
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
        if identifier.rawValue == "print" {
            printButton.title = L10n.string("button.print")
            printButton.image = NSImage(systemSymbolName: "printer", accessibilityDescription: nil)
            printButton.imagePosition = .imageLeading
            printButton.bezelStyle = .texturedRounded
            printButton.font = .systemFont(ofSize: 13, weight: .medium)
            printButton.target = self; printButton.action = #selector(printPDF)
            printButton.setAccessibilityLabel(L10n.string("button.print"))
            printButton.toolTip = L10n.string("print.shortcut_hint")
            printButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
            printButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
            item.view = printButton; item.label = printButton.title; item.toolTip = printButton.toolTip
            item.target = self; item.action = #selector(printPDF)
            item.visibilityPriority = .high
            let entry = NSMenuItem(title: printButton.title, action: #selector(printPDF), keyEquivalent: "")
            entry.target = self; item.menuFormRepresentation = entry
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
        queueHint.isHidden = queueCollapsed || sourceItems.count < 2
        queueDisclosure.image = NSImage(systemSymbolName: queueCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        queueDisclosure.setAccessibilityValue(L10n.string(queueCollapsed ? "queue.collapsed" : "queue.expanded"))
    }
    @objc func toggleMoreSettings() {
        setMoreSettingsExpanded(!moreSettingsExpanded)
        preferences.set(moreSettingsExpanded, forKey: "moreSettingsExpanded")
    }

    func setMoreSettingsExpanded(_ expanded: Bool) {
        // Move focus before hiding a field currently being edited.
        if moreSettingsExpanded && !expanded { window?.makeFirstResponder(moreSettingsButton) }
        moreSettingsExpanded = expanded
        moreSettingsContent.isHidden = !expanded
        moreSettingsButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        moreSettingsButton.setAccessibilityValue(L10n.string(expanded ? "queue.expanded" : "queue.collapsed"))
        updateMoreSettingsHint()
    }

    func updateMoreSettingsHint() {
        moreSettingsHint.isHidden = moreSettingsExpanded
        let range = rangeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if margins.indexOfSelectedItem == 0 && borderCheckbox.state == .off && range.isEmpty {
            moreSettingsHint.stringValue = L10n.string("settings.more_hint")
        } else {
            let margin = [10, 5, 15][max(0, min(margins.indexOfSelectedItem, 2))]
            moreSettingsHint.stringValue = L10n.format("settings.more_summary", margin,
                L10n.string(borderCheckbox.state == .on ? "settings.borders_on" : "settings.borders_off"),
                range.isEmpty ? L10n.string("range.all") : range)
        }
        moreSettingsHint.toolTip = moreSettingsHint.stringValue
    }

    func syncCountPresets() {
        if let count = Int(countField.stringValue.trimmingCharacters(in: .whitespaces)) {
            countPresets.selectedSegment = presetCounts.firstIndex(of: count) ?? -1
            if (1...16).contains(count) { countStepper.integerValue = count }
        } else { countPresets.selectedSegment = -1 }
    }

    @objc func chooseCountPreset() {
        guard presetCounts.indices.contains(countPresets.selectedSegment) else { return }
        let count = presetCounts[countPresets.selectedSegment]
        // Commit the field editor before applying the new preset.
        window.makeFirstResponder(countPresets)
        countField.integerValue = count
        regenerate()
    }

    func setStatus(_ text: String) {
        status.stringValue = text; status.toolTip = text; status.isHidden = text.isEmpty
    }

    @objc func showPrintHelp() {
        guard outputDocument != nil else { return }
        let title = label(L10n.string("print.help_title"), size: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: printHelpText)
        body.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let controller = NSViewController(); controller.view = NSView()
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -16),
            body.widthAnchor.constraint(equalToConstant: 280)
        ])
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        printHelpPopover = popover
        popover.show(relativeTo: printHelpButton.bounds, of: printHelpButton, preferredEdge: .maxY)
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

    var currentPrintLayout: PrintLayout? {
        guard let count = Int(countField.stringValue.trimmingCharacters(in: .whitespaces)) else { return nil }
        let layout = PrintLayout(pagesPerSheet: count, paperIndex: paperPopup.indexOfSelectedItem,
            landscape: orientation.selectedSegment == 1, arrangement: arrangement.indexOfSelectedItem,
            marginIndex: margins.indexOfSelectedItem, showsBorders: borderCheckbox.state == .on)
        return layout.isValid ? layout : nil
    }

    func syncPrintPresets() {
        let layout = currentPrintLayout
        let matching = presetStore.presets.filter { $0.layout == layout }
        selectedPresetID = matching.first(where: { $0.id == selectedPresetID })?.id ?? matching.first?.id
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(withTitle: L10n.string("preset.custom"), action: nil, keyEquivalent: "").tag = 0
        for preset in presetStore.presets {
            let item = menu.addItem(withTitle: preset.name, action: nil, keyEquivalent: "")
            item.representedObject = preset.id.uuidString
            item.toolTip = L10n.format("detail.compact_result", ["A4", "A3", "Letter"][preset.layout.paperIndex],
                L10n.string(preset.layout.landscape ? "orientation.landscape" : "orientation.portrait"), preset.layout.pagesPerSheet)
        }
        menu.addItem(.separator())
        for (key, tag, enabled) in [("preset.save", -1, layout != nil),
                                   ("preset.rename", -2, selectedPresetID != nil),
                                   ("preset.delete", -3, selectedPresetID != nil)] {
            let item = menu.addItem(withTitle: L10n.string(key), action: nil, keyEquivalent: "")
            item.tag = tag; item.isEnabled = enabled
        }
        layoutPresetPopup.menu = menu
        if let selectedPresetID, let item = menu.items.first(where: { ($0.representedObject as? String) == selectedPresetID.uuidString }) {
            layoutPresetPopup.select(item)
        } else { layoutPresetPopup.selectItem(at: 0) }
        layoutPresetPopup.toolTip = layoutPresetPopup.title
        layoutPresetPopup.isEnabled = sourceDocument != nil
    }

    @objc func choosePrintPreset() {
        guard let item = layoutPresetPopup.selectedItem else { return }
        let tag = item.tag
        let identifier = (item.representedObject as? String).flatMap(UUID.init(uuidString:))
        let previousID = selectedPresetID
        // Finish a live field edit before replacing the settings it contains.
        window.makeFirstResponder(layoutPresetPopup)
        if let identifier, let preset = presetStore.presets.first(where: { $0.id == identifier }) {
            let layout = preset.layout
            countField.integerValue = layout.pagesPerSheet
            paperPopup.selectItem(at: layout.paperIndex)
            orientation.selectedSegment = layout.landscape ? 1 : 0
            arrangement.selectItem(at: layout.arrangement)
            margins.selectItem(at: layout.marginIndex)
            borderCheckbox.state = layout.showsBorders ? .on : .off
            selectedPresetID = identifier
            regenerate()
            return
        }
        syncPrintPresets()
        if tag == -1, let layout = currentPrintLayout { promptPresetName(existing: nil, layout: layout) }
        if tag == -2, let preset = presetStore.presets.first(where: { $0.id == previousID }) {
            promptPresetName(existing: preset, layout: preset.layout)
        }
        if tag == -3, let preset = presetStore.presets.first(where: { $0.id == previousID }) {
            let alert = NSAlert(); alert.messageText = L10n.format("preset.delete_title", preset.name)
            alert.informativeText = L10n.string("preset.delete_hint")
            alert.addButton(withTitle: L10n.string("preset.delete_button"))
            alert.addButton(withTitle: L10n.string("button.cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                do {
                    try self.presetStore.remove(id: preset.id)
                    self.selectedPresetID = nil; self.syncPrintPresets()
                } catch { self.showError(error.localizedDescription) }
            }
        }
    }

    func promptPresetName(existing: SavedPrintPreset?, layout: PrintLayout) {
        let alert = NSAlert()
        alert.messageText = L10n.string(existing == nil ? "preset.save_title" : "preset.rename_title")
        alert.informativeText = L10n.string("preset.save_hint")
        let field = NSTextField(string: existing?.name ?? "")
        field.placeholderString = L10n.string("preset.name_placeholder")
        field.setAccessibilityLabel(L10n.string("preset.name_label"))
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let validation = NSTextField(wrappingLabelWithString: " ")
        validation.font = .systemFont(ofSize: 11); validation.textColor = .secondaryLabelColor
        validation.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let accessory = NSStackView(views: [field, validation])
        accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        alert.accessoryView = accessory
        let save = alert.addButton(withTitle: L10n.string("preset.save_button"))
        alert.addButton(withTitle: L10n.string("button.cancel"))
        let validate = { [weak self] in
            guard let self else { return }
            do {
                _ = try self.presetStore.validatedName(field.stringValue, excluding: existing?.id)
                validation.stringValue = " "; save.isEnabled = true
            } catch {
                validation.stringValue = error.localizedDescription; save.isEnabled = false
            }
        }
        validate()
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in validate() }
        alert.window.initialFirstResponder = field
        (alert.window.fieldEditor(true, for: field) as? NSTextView)?.allowsUndo = true
        alert.beginSheetModal(for: window) { [weak self] response in
            NotificationCenter.default.removeObserver(observer)
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                if let existing {
                    try self.presetStore.rename(id: existing.id, name: field.stringValue)
                    self.selectedPresetID = existing.id
                } else {
                    self.selectedPresetID = try self.presetStore.add(name: field.stringValue, layout: layout).id
                }
                self.syncPrintPresets()
            } catch { self.showError(error.localizedDescription) }
        }
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
        let fieldLabel = label(title, size: 12, weight: .regular)
        fieldLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [fieldLabel, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
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
        stack.setCustomSpacing(16, after: heading)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    func buildSidebar(in sidebar: NSView) {
        countField.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        countField.alignment = .center
        countField.delegate = self
        countField.setAccessibilityLabel(L10n.string("accessibility.pages_per_sheet"))
        countField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        countField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        countStepper.minValue = 1; countStepper.maxValue = 16; countStepper.increment = 1
        countStepper.target = self; countStepper.action = #selector(stepCount)
        countStepper.setAccessibilityLabel(L10n.string("accessibility.pages_per_sheet"))
        let customLabel = label(L10n.string("count.custom"), size: 11, weight: .regular)
        customLabel.textColor = .secondaryLabelColor
        let countRow = NSStackView(views: [customLabel, NSView(), countField, countStepper])
        countRow.spacing = 8
        countPresets.target = self; countPresets.action = #selector(chooseCountPreset)
        countPresets.segmentDistribution = .fillEqually
        countPresets.segmentStyle = .rounded
        countPresets.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countPresets.heightAnchor.constraint(equalToConstant: 28).isActive = true
        countPresets.setAccessibilityLabel(L10n.string("count.presets"))
        for (index, value) in presetCounts.enumerated() {
            countPresets.setToolTip(L10n.format("count.preset_hint", value), forSegment: index)
        }
        paperPopup.addItems(withTitles: [L10n.string("paper.a4"), L10n.string("paper.a3"), L10n.string("paper.letter")])
        orientation.segmentDistribution = .fillEqually
        orientation.segmentStyle = .rounded
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
        controls = [countPresets, countField, countStepper, paperPopup, orientation, arrangement, margins, borderCheckbox, rangeField]
        restoreSettings()
        syncCountPresets()
        layoutPresetPopup.target = self; layoutPresetPopup.action = #selector(choosePrintPreset)
        layoutPresetPopup.setAccessibilityLabel(L10n.string("preset.label"))
        layoutPresetPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncPrintPresets()
        let countGroup = section(L10n.string("label.pages_per_sheet"), countPresets)
        countGroup.addArrangedSubview(countRow)
        countRow.widthAnchor.constraint(equalTo: countGroup.widthAnchor).isActive = true

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
        sourceQueueBox.orientation = .vertical; sourceQueueBox.alignment = .leading; sourceQueueBox.spacing = 8
        for view in [header, sourceList, queueHint] { view.widthAnchor.constraint(equalTo: sourceQueueBox.widthAnchor).isActive = true }

        let layout = group(L10n.string("group.layout"), views: [section(L10n.string("preset.label"), layoutPresetPopup), countGroup,
            section(L10n.string("section.paper"), paperPopup),
            section(L10n.string("section.orientation"), orientation), section(L10n.string("section.arrangement"), arrangement)])
        moreSettingsButton.title = L10n.string("settings.more")
        moreSettingsButton.imagePosition = .imageLeading; moreSettingsButton.isBordered = false
        moreSettingsButton.font = .systemFont(ofSize: 13, weight: .semibold)
        moreSettingsButton.target = self; moreSettingsButton.action = #selector(toggleMoreSettings)
        moreSettingsButton.setAccessibilityLabel(L10n.string("settings.more"))
        moreSettingsButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        moreSettingsContent.setViews([section(L10n.string("section.margin"), margins), borderCheckbox,
            section(L10n.string("section.page_range"), rangeField)], in: .top)
        moreSettingsContent.orientation = .vertical; moreSettingsContent.alignment = .leading; moreSettingsContent.spacing = 12
        for view in moreSettingsContent.arrangedSubviews { view.widthAnchor.constraint(equalTo: moreSettingsContent.widthAnchor).isActive = true }
        moreSettingsHint.font = .systemFont(ofSize: 11); moreSettingsHint.textColor = .secondaryLabelColor
        moreSettingsHint.maximumNumberOfLines = 2; moreSettingsHint.lineBreakMode = .byTruncatingTail
        let advanced = NSStackView(views: [moreSettingsButton, moreSettingsHint, moreSettingsContent])
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing = 8
        moreSettingsContent.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true
        moreSettingsHint.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true
        let savedExpansion = preferences.object(forKey: "moreSettingsExpanded") as? Bool
        setMoreSettingsExpanded(savedExpansion ?? (margins.indexOfSelectedItem != 0 || borderCheckbox.state == .on))
        let stack = NSStackView(views: [sourceQueueBox, separator(), layout, separator(), advanced])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
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
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
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
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        summary.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle; status.isHidden = true
        let info = NSStackView(views: [summary, detail])
        info.orientation = .vertical; info.alignment = .leading; info.spacing = 4
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for field in [summary, detail] { field.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true }
        printHelpButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: L10n.string("print.help_title"))
        printHelpButton.isBordered = false; printHelpButton.contentTintColor = .secondaryLabelColor
        printHelpButton.target = self; printHelpButton.action = #selector(showPrintHelp)
        printHelpButton.toolTip = L10n.string("print.help_title")
        printHelpButton.setAccessibilityLabel(L10n.string("print.help_title"))
        printHelpButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        printHelpButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let navigation = NSStackView(views: [previousButton, pageLabel, nextButton])
        navigation.spacing = 8
        navigation.widthAnchor.constraint(equalTo: pageLabel.widthAnchor, constant: 80).isActive = true
        navigation.setContentHuggingPriority(.required, for: .horizontal)
        navigation.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footerRow = NSStackView(views: [info, navigation, printHelpButton])
        footerRow.spacing = 12; footerRow.alignment = .centerY; footerRow.distribution = .fill
        let footer = NSStackView(views: [footerRow, status])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerRow.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        previewContent.addSubview(footer)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor), thumbnailView.widthAnchor.constraint(equalToConstant: 76),
            thumbnailView.topAnchor.constraint(equalTo: previewContent.topAnchor), thumbnailView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            pdfView.topAnchor.constraint(equalTo: previewContent.topAnchor), pdfView.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor), pdfView.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor, constant: -12)
        ])
        renderingBadge.material = .popover; renderingBadge.blendingMode = .withinWindow
        renderingBadge.wantsLayer = true; renderingBadge.layer?.cornerRadius = 9
        renderingBadge.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        renderingLabel.font = .systemFont(ofSize: 12)
        renderingLabel.lineBreakMode = .byTruncatingTail
        renderingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let progress = NSStackView(views: [spinner, renderingLabel])
        progress.spacing = 8; progress.translatesAutoresizingMaskIntoConstraints = false
        renderingBadge.addSubview(progress); previewContent.addSubview(renderingBadge)
        NSLayoutConstraint.activate([
            renderingBadge.widthAnchor.constraint(lessThanOrEqualTo: pdfView.widthAnchor, constant: -24),
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
        emptyTitle.font = .systemFont(ofSize: 26, weight: .semibold); emptyTitle.alignment = .center
        let emptyText = NSTextField(wrappingLabelWithString: L10n.string("empty.text"))
        emptyText.font = .systemFont(ofSize: 13); emptyText.textColor = .secondaryLabelColor; emptyText.alignment = .center
        emptyView.setViews([icon, emptyTitle, emptyText, button(L10n.string("toolbar.add"), #selector(openPanel))], in: .center)
        emptyView.orientation = .vertical; emptyView.spacing = 16; emptyView.translatesAutoresizingMaskIntoConstraints = false
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
            let additions = Set(urls.map(\.standardizedFileURL)).filter { !sourceURLs.contains($0) }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            guard !additions.isEmpty else { return }
            var items = sourceItems
            for url in additions {
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
            }
            let state = SourceQueueState(items: items, urls: sourceURLs + additions,
                selectedIndex: sourceItems.count, pageRange: "")
            replaceSourceQueue(with: state, actionName: L10n.string("undo.add_files"))
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
        sourceQueueHeightConstraint.constant = min(max(CGFloat(sourceItems.count) * 56 + 16, 72), 184)
        sourceList.update(sources: sourceItems, selectedIndex: selectedIndex)
        queueHint.isHidden = queueCollapsed || sourceItems.count < 2
    }

    func makePreviewDocument(sources: [PDFSource]) throws -> PDFDocument {
        let previewDocument = PDFDocument()
        for source in sources {
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

    var sourceQueueState: SourceQueueState {
        SourceQueueState(items: sourceItems, urls: sourceURLs, selectedIndex: sourceList.selectedIndex,
            pageRange: rangeField.stringValue)
    }

    func replaceSourceQueue(with state: SourceQueueState, actionName: String) {
        do {
            // Prepare everything before changing the visible queue or its undo history.
            let preview = state.items.isEmpty ? nil : try makePreviewDocument(sources: state.items)
            window.makeFirstResponder(nil)
            let previous = sourceQueueState
            let isReplaying = queueUndoManager.isUndoing || queueUndoManager.isRedoing
            if !isReplaying { queueUndoManager.beginUndoGrouping() }
            queueUndoManager.registerUndo(withTarget: self) { target in
                target.replaceSourceQueue(with: previous, actionName: actionName)
            }
            queueUndoManager.setActionName(actionName)
            if !isReplaying { queueUndoManager.endUndoGrouping() }
            let wasEmpty = sourceItems.isEmpty
            sourceItems = state.items; sourceURLs = state.urls; sourceDocument = preview
            rangeField.stringValue = state.pageRange
            refreshSourceQueue(selectedIndex: state.selectedIndex)
            if !sourceItems.isEmpty {
                if wasEmpty { sidebarItem.isCollapsed = preferences.bool(forKey: "sidebarCollapsed") }
                updateSourceMetadata()
                if mode.selectedSegment == 0 { pdfView.document = preview }
                regenerate()
                if !sidebarItem.isCollapsed && !queueCollapsed { sourceList.focusSelectedRow() }
            } else {
                sourceTitle.stringValue = L10n.string("source.no_pdf")
                sourceDetail.stringValue = L10n.string("source.local_only")
                sourceTitle.toolTip = nil
                displayedPreview = nil; savedPreviewPage = 0; savedPreviewScale = nil
                sidebarItem.isCollapsed = true
                pendingRender?.cancel()
                pdfView.document = nil
                pageLabel.stringValue = ""
                window.title = L10n.string("app.name"); window.representedURL = nil
                invalidateOutput()
                summary.stringValue = L10n.string("summary.ready")
                detail.stringValue = L10n.string("detail.default")
                setStatus("")
                updateAvailability()
            }
        } catch { showError(error.localizedDescription) }
    }

    func moveSource(from index: Int, to destination: Int) {
        guard sourceItems.indices.contains(index), sourceItems.indices.contains(destination), index != destination else { return }
        var state = sourceQueueState
        state.items.insert(state.items.remove(at: index), at: destination)
        state.urls.insert(state.urls.remove(at: index), at: destination)
        state.selectedIndex = destination
        replaceSourceQueue(with: state, actionName: L10n.string("undo.reorder_files"))
    }

    func removeSource(at index: Int) {
        guard sourceItems.indices.contains(index) else { return }
        var state = sourceQueueState
        state.items.remove(at: index); state.urls.remove(at: index)
        state.selectedIndex = min(index, state.items.count - 1)
        if state.items.isEmpty { state.pageRange = "" }
        replaceSourceQueue(with: state, actionName: L10n.string("undo.remove_file"))
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
    func controlTextDidBeginEditing(_ notification: Notification) {
        (window.firstResponder as? NSTextView)?.allowsUndo = true
    }
    func controlTextDidChange(_ notification: Notification) {
        syncCountPresets()
        syncPrintPresets()
        updateMoreSettingsHint()
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
        syncCountPresets()
        syncPrintPresets()
        updateMoreSettingsHint()
        invalidateOutput()
        guard !sourceItems.isEmpty else { return }
        let settings: PrintSettings
        do { settings = try readSettings() }
        catch {
            if let count = Int(countField.stringValue.trimmingCharacters(in: .whitespaces)),
               (1...16).contains(count), !rangeField.stringValue.isEmpty { setMoreSettingsExpanded(true) }
            isRendering = false; spinner.stopAnimation(nil)
            renderingLabel.stringValue = L10n.string("preview.previous")
            summary.stringValue = L10n.string("summary.check_settings")
            detail.stringValue = error.localizedDescription; setStatus("")
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
        summary.stringValue = L10n.string("summary.generating"); detail.stringValue = ""; setStatus("")
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
                    self.summary.stringValue = L10n.format("summary.compact_result", settings.pageIndices.count, result.sheetCount)
                    let orientation = L10n.string(settings.landscape ? "orientation.landscape" : "orientation.portrait")
                    self.detail.stringValue = L10n.format("detail.compact_result", settings.paperName, orientation, settings.pagesPerSheet)
                    self.detail.toolTip = L10n.format("detail.result", settings.paperName, orientation, settings.pagesPerSheet, result.rows, result.columns)
                    self.printHelpText = L10n.format("status.print_sheets", result.sheetCount) + "\n\n" + L10n.string("print.layout_hint")
                    self.setStatus("")
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
        printButton.isEnabled = outputDocument != nil
        printHelpButton.isEnabled = outputDocument != nil
        if outputDocument == nil { printHelpPopover?.close() }
        previewContent.isHidden = !hasSource
        emptyView.isHidden = hasSource
        mode.isEnabled = hasSource
        layoutPresetPopup.isEnabled = hasSource
        for control in controls { control.isEnabled = hasSource }
        renderingBadge.isHidden = !hasSource || mode.selectedSegment == 0 || (outputDocument != nil && !isRendering)
        updatePageLabel()
        renderingLabel.toolTip = renderingLabel.stringValue
        detail.toolTip = outputDocument == nil ? detail.stringValue : detail.toolTip
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
            do { try data.write(to: url, options: .atomic); self?.setStatus(L10n.format("status.saved", url.lastPathComponent)) }
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
