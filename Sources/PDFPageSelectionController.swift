import AppKit

/// Edits one document's original page numbers without changing its PDF data.
final class PDFPageSelectionController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var onDismiss: (() -> Void)?

    private let source: PDFSource
    private let onApply: ([Int]?) -> Void
    private let mode = NSSegmentedControl()
    private let rangeField = NSTextField(string: "")
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton()
    private var validatedSelection: [Int]?
    private var isValid = false
    private var isPresented = false
    private var isFinishing = false

    init(source: PDFSource, resetsCombinedRange: Bool = false,
         onApply: @escaping ([Int]?) -> Void) {
        self.source = source
        self.onApply = onApply
        let panel = PageSelectionPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L10n.string("selection.title")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(applying: false) }
        buildContent(resetsCombinedRange: resetsCombinedRange)
        mode.selectedSegment = source.selectedPageIndices == nil ? 0 : 1
        if let indices = source.selectedPageIndices {
            rangeField.stringValue = Self.rangeText(indices)
        }
        updateValidation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(on parent: NSWindow) {
        guard !isPresented, let window, parent.attachedSheet == nil else { return }
        isPresented = true
        isFinishing = false
        window.initialFirstResponder = mode.selectedSegment == 1 ? rangeField : mode
        (window.fieldEditor(true, for: rangeField) as? NSTextView)?.allowsUndo = true
        // The completion retains the controller until the sheet has actually closed.
        parent.beginSheet(window) { [self] response in
            isPresented = false
            if response == .OK { onApply(validatedSelection) }
            onDismiss?()
        }
    }

    private func buildContent(resetsCombinedRange: Bool) {
        guard let window, let content = window.contentView else { return }
        let title = NSTextField(labelWithString: L10n.string("selection.title"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let filename = NSTextField(labelWithString: source.name)
        filename.font = .systemFont(ofSize: 13, weight: .medium)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.toolTip = source.name
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let total = NSTextField(labelWithString: L10n.format("selection.total", source.pageCount))
        total.font = .systemFont(ofSize: 11)
        total.textColor = .secondaryLabelColor
        let heading = verticalStack([title, filename, total], spacing: 5)

        mode.segmentCount = 2
        mode.setLabel(L10n.string("selection.all"), forSegment: 0)
        mode.setLabel(L10n.string("selection.custom"), forSegment: 1)
        mode.trackingMode = .selectOne
        mode.segmentDistribution = .fillEqually
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel(L10n.string("selection.mode"))

        let rangeLabel = NSTextField(labelWithString: L10n.string("selection.range_label"))
        rangeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        rangeField.placeholderString = L10n.string("selection.placeholder")
        rangeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        rangeField.delegate = self
        rangeField.setAccessibilityLabel(L10n.string("selection.range_label"))
        rangeField.setAccessibilityHelp(L10n.string("selection.range_hint"))
        let hint = wrappingLabel("selection.range_hint")
        let rangeGroup = verticalStack([rangeLabel, rangeField, hint], spacing: 6)

        validationLabel.font = .systemFont(ofSize: 12)
        validationLabel.maximumNumberOfLines = 2
        validationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        let explanation = wrappingLabel(resetsCombinedRange ? "selection.effect_reset" : "selection.effect")
        let separator = NSBox()
        separator.boxType = .separator

        let cancel = NSButton(title: L10n.string("selection.cancel"), target: self, action: #selector(cancelSelection))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        applyButton.title = L10n.string("selection.apply")
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applySelection)
        applyButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = verticalStack([heading, mode, rangeGroup, validationLabel, explanation, separator, buttons], spacing: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 432)
        ])
        for view in [heading, mode, rangeGroup, validationLabel, explanation, separator, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in [rangeLabel, rangeField, hint] {
            view.widthAnchor.constraint(equalTo: rangeGroup.widthAnchor).isActive = true
        }
        for view in [title, filename, total] {
            view.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 480, height: stack.fittingSize.height + 44))
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func wrappingLabel(_ key: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L10n.string(key))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func modeChanged() {
        updateValidation()
        if mode.selectedSegment == 1 { window?.makeFirstResponder(rangeField) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (rangeField.currentEditor() as? NSTextView)?.allowsUndo = true
    }

    func controlTextDidChange(_ obj: Notification) { updateValidation() }

    private func updateValidation() {
        let custom = mode.selectedSegment == 1
        rangeField.isEnabled = custom
        do {
            guard source.pageCount > 0 else { throw LayoutError.message(L10n.string("selection.empty_document")) }
            var indices: [Int]?
            if custom {
                guard !rangeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LayoutError.message(L10n.string("selection.required"))
                }
                let selected = try Imposition.pageIndices(rangeField.stringValue, count: source.pageCount).sorted()
                guard !selected.isEmpty else { throw LayoutError.message(L10n.string("selection.required")) }
                indices = selected.count == source.pageCount ? nil : selected
            }
            validatedSelection = indices
            validationLabel.stringValue = L10n.format("selection.count", indices?.count ?? source.pageCount, source.pageCount)
            validationLabel.textColor = .secondaryLabelColor
            isValid = true
        } catch {
            validatedSelection = nil
            validationLabel.stringValue = error.localizedDescription
            validationLabel.textColor = .systemRed
            isValid = false
        }
        applyButton.isEnabled = isValid
    }

    @objc private func cancelSelection() { finish(applying: false) }
    @objc private func applySelection() { finish(applying: true) }

    private func finish(applying: Bool) {
        guard isPresented, !isFinishing, let window, let parent = window.sheetParent else { return }
        if applying {
            updateValidation()
            guard isValid else { return }
        }
        isFinishing = true
        window.makeFirstResponder(nil)
        parent.endSheet(window, returnCode: applying ? .OK : .cancel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(applying: false)
        return false
    }

    /// Display a compact, editable range while preserving original PDF order.
    private static func rangeText(_ indices: [Int]) -> String {
        let pages = Array(Set(indices)).sorted().map { $0 + 1 }
        guard let first = pages.first else { return "" }
        var parts: [String] = []
        var start = first
        var end = first
        for page in pages.dropFirst() {
            if page == end + 1 { end = page; continue }
            parts.append(start == end ? "\(start)" : "\(start)-\(end)")
            start = page
            end = page
        }
        parts.append(start == end ? "\(start)" : "\(start)-\(end)")
        return parts.joined(separator: ",")
    }
}

private final class PageSelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
