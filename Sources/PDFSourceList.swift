import AppKit

/// A native, keyboard-accessible list of the documents in a print job.
final class PDFSourceList: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    var onRemove: ((Int) -> Void)?
    /// The second index is the final index after removing the source row.
    var onMove: ((Int, Int) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    var selectedIndex: Int { tableView.selectedRow }

    private let tableView = SourceTableView()
    private let scrollView = NSScrollView()
    private var sources: [PDFSource] = []
    private var contentRevision = 0
    private static let rowType = NSPasteboard.PasteboardType("com.songningning.pdfpinprint.source-row")
    private static let columnID = NSUserInterfaceItemIdentifier("source")
    private static let cellID = NSUserInterfaceItemIdentifier("source-cell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        column.minWidth = 140
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 62
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.autoresizingMask = [.width]
        tableView.selectionHighlightStyle = .regular
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(L10n.string("queue.title"))
        tableView.registerForDraggedTypes([Self.rowType, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)
        tableView.onDelete = { [weak self] in self?.removeSelectedRow() }
        tableView.onMove = { [weak self] offset in self?.moveSelectedRow(by: offset) }

        let menu = NSMenu()
        menu.addItem(menuItem("queue.move_up", action: #selector(moveSelectedUp)))
        menu.addItem(menuItem("queue.move_down", action: #selector(moveSelectedDown)))
        menu.addItem(.separator())
        menu.addItem(menuItem("queue.remove", action: #selector(removeSelectedRow)))
        tableView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(sources: [PDFSource], selectedIndex: Int? = nil) {
        let requestedSelection = selectedIndex ?? tableView.selectedRow
        self.sources = sources
        contentRevision += 1
        tableView.reloadData()
        if sources.isEmpty {
            tableView.deselectAll(nil)
        } else {
            selectRow(min(max(requestedSelection, 0), sources.count - 1), scroll: false)
        }
    }

    func focusSelectedRow() {
        if tableView.selectedRow < 0, !sources.isEmpty { selectRow(0) }
        window?.makeFirstResponder(tableView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sources.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? SourceCellView)
            ?? SourceCellView(frame: .zero)
        cell.identifier = Self.cellID
        cell.configure(source: sources[row])
        cell.onRemove = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let currentRow = self.tableView.row(for: cell)
            guard self.sources.indices.contains(currentRow) else { return }
            self.selectRow(currentRow, scroll: false)
            self.removeSelectedRow()
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard sources.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(contentRevision):\(row)", forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let insertionRow = max(0, min(row, sources.count))
        if let sourceRow = internalDragRow(info) {
            tableView.setDropRow(insertionRow, dropOperation: .above)
            let destination = insertionRow > sourceRow ? insertionRow - 1 : insertionRow
            return destination != sourceRow && onMove != nil ? .move : []
        }
        // A stale or foreign custom row payload must never become an external file drop.
        guard info.draggingPasteboard.types?.contains(Self.rowType) != true,
              onDropFiles != nil, !pdfURLs(from: info).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if let sourceRow = internalDragRow(info) {
            let insertionRow = max(0, min(row, sources.count))
            let destination = insertionRow > sourceRow ? insertionRow - 1 : insertionRow
            guard sources.indices.contains(destination), destination != sourceRow, let onMove else { return false }
            onMove(sourceRow, destination)
            selectRow(destination)
            return true
        }
        guard info.draggingPasteboard.types?.contains(Self.rowType) != true, let onDropFiles else { return false }
        let urls = pdfURLs(from: info)
        guard !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    private func internalDragRow(_ info: NSDraggingInfo) -> Int? {
        guard let source = info.draggingSource as? NSTableView, source === tableView,
              let payload = info.draggingPasteboard.string(forType: Self.rowType) else { return nil }
        let components = payload.split(separator: ":")
        guard components.count == 2, let revision = Int(components[0]), revision == contentRevision,
              let row = Int(components[1]), sources.indices.contains(row) else { return nil }
        return row
    }

    private func pdfURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
    }

    private func selectRow(_ row: Int, scroll: Bool = true) {
        guard sources.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll { tableView.scrollRowToVisible(row) }
    }

    private func menuItem(_ key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(key), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let row = selectedIndex
        guard sources.indices.contains(row) else { return false }
        if menuItem.action == #selector(moveSelectedUp) { return row > 0 && onMove != nil }
        if menuItem.action == #selector(moveSelectedDown) { return row + 1 < sources.count && onMove != nil }
        if menuItem.action == #selector(removeSelectedRow) { return onRemove != nil }
        return false
    }

    @objc private func removeSelectedRow() {
        let row = selectedIndex
        guard sources.indices.contains(row), let onRemove else { return }
        onRemove(row)
        if !sources.isEmpty {
            selectRow(min(row, sources.count - 1))
            window?.makeFirstResponder(tableView)
        }
    }

    @objc private func moveSelectedUp() { moveSelectedRow(by: -1) }
    @objc private func moveSelectedDown() { moveSelectedRow(by: 1) }

    private func moveSelectedRow(by offset: Int) {
        let row = selectedIndex
        let destination = row + offset
        guard sources.indices.contains(row), sources.indices.contains(destination), let onMove else { return }
        onMove(row, destination)
        selectRow(destination)
        window?.makeFirstResponder(tableView)
    }
}

private final class SourceTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onMove: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            onDelete?()
            return
        }
        if modifiers == .option && (event.keyCode == 125 || event.keyCode == 126) {
            onMove?(event.keyCode == 126 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

private final class SourceCellView: NSTableCellView {
    var onRemove: (() -> Void)?
    private let thumbnail = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityElement(false)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = nameLabel
        imageView = thumbnail

        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let removeLabel = L10n.string("queue.remove")
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: removeLabel)
        removeButton.imagePosition = .imageOnly
        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = removeLabel
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.setAccessibilityLabel(removeLabel)

        let content = NSStackView(views: [thumbnail, text, removeButton])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        addSubview(content)
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: 32),
            thumbnail.heightAnchor.constraint(equalToConstant: 46),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
            removeButton.heightAnchor.constraint(equalToConstant: 28),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(source: PDFSource) {
        thumbnail.image = source.thumbnail ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        nameLabel.stringValue = source.name
        let detailKey = source.allowsPrinting ? "queue.ready" : "queue.print_restricted"
        detailLabel.stringValue = L10n.format(detailKey, source.pageCount)
        detailLabel.textColor = source.allowsPrinting ? .secondaryLabelColor : .systemOrange
        toolTip = "\(source.name)\n\(detailLabel.stringValue)"
        removeButton.setAccessibilityLabel("\(L10n.string("queue.remove")): \(source.name)")
    }

    @objc private func remove() { onRemove?() }
}
