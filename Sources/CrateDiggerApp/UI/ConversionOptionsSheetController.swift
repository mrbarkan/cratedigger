import AppKit
import CrateDiggerCore

enum ConversionBatchScope: Int, CaseIterable {
    case selectedTracks
    case allLoadedTracks

    var title: String {
        switch self {
        case .selectedTracks:
            return "Selected Tracks"
        case .allLoadedTracks:
            return "All Loaded Tracks"
        }
    }
}

struct ConversionOptionsSelection {
    let batchScope: ConversionBatchScope
    let outputFormat: OutputFormat
    let bitrate: Int?
    let sampleRate: Int?
    let folderStructureMode: FolderStructureMode
    let applyMode: TemplateApplyMode
    let templatePreset: TemplatePreset
    let tokenOrder: [FolderToken]
}

final class ConversionOptionsSheetController: NSViewController {
    var onDecision: ((ConversionOptionsSelection?) -> Void)?

    private let outputFormats: [OutputFormat]
    private let bitrateOptions: [Int]
    private let sampleRateOptions: [Int]
    private let initialSelection: ConversionOptionsSelection

    private let batchScopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bitratePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sampleRatePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderStructurePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let templatePresetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenPopUp1 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenPopUp2 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenPopUp3 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenPopUp4 = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokenPopUp5 = NSPopUpButton(frame: .zero, pullsDown: false)

    private let templateSection = NSStackView()
    private let customTokenSection = NSStackView()

    init(
        initialSelection: ConversionOptionsSelection,
        outputFormats: [OutputFormat],
        bitrateOptions: [Int],
        sampleRateOptions: [Int]
    ) {
        self.initialSelection = initialSelection
        self.outputFormats = outputFormats
        self.bitrateOptions = bitrateOptions
        self.sampleRateOptions = sampleRateOptions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        ClassicTheme.applyMetal(to: view)
        view.translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        configurePopups()
        applyInitialSelection()
        updateFormatDependentControls()
        updateTemplateVisibility()
    }

    private var tokenPopups: [NSPopUpButton] {
        [tokenPopUp1, tokenPopUp2, tokenPopUp3, tokenPopUp4, tokenPopUp5]
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Conversion Options")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.15, alpha: 0.95)

        let topRow = NSStackView(views: [
            makeLabeledRow("Batch", batchScopePopUp),
            makeLabeledRow("Format", formatPopUp),
            makeLabeledRow("Bitrate", bitratePopUp),
            makeLabeledRow("Sample Rate", sampleRatePopUp)
        ])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = 12
        topRow.distribution = .fillEqually

        let folderRow = NSStackView(views: [
            makeLabeledRow("Folder Structure", folderStructurePopUp),
            makeLabeledRow("Apply Mode", applyModePopUp)
        ])
        folderRow.orientation = .horizontal
        folderRow.alignment = .top
        folderRow.spacing = 12
        folderRow.distribution = .fillEqually

        let templatePresetRow = makeLabeledRow("Folder Order", templatePresetPopUp)

        customTokenSection.orientation = .vertical
        customTokenSection.alignment = .leading
        customTokenSection.spacing = 5
        let tokensLabel = NSTextField(labelWithString: "Token Order")
        tokensLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        tokensLabel.textColor = NSColor(calibratedWhite: 0.25, alpha: 0.9)

        let tokenRow = NSStackView(views: tokenPopups)
        tokenRow.orientation = .horizontal
        tokenRow.spacing = 8
        tokenRow.alignment = .centerY
        customTokenSection.addArrangedSubview(tokensLabel)
        customTokenSection.addArrangedSubview(tokenRow)

        templateSection.orientation = .vertical
        templateSection.alignment = .leading
        templateSection.spacing = 8
        templateSection.addArrangedSubview(templatePresetRow)
        templateSection.addArrangedSubview(customTokenSection)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.bezelStyle = .rounded

        let continueButton = NSButton(title: "Continue", target: self, action: #selector(continueAction))
        ClassicTheme.applyAquaAccent(to: continueButton)
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 94).isActive = true
        continueButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let buttonRow = NSStackView(views: [cancelButton, continueButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        buttonRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let mainStack = NSStackView(views: [title, topRow, folderRow, templateSection, buttonRow])
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .leading
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            buttonRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor)
        ])
    }

    private func makeLabeledRow(_ title: String, _ control: NSControl) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.25, alpha: 0.9)

        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        return stack
    }

    private func configurePopups() {
        let popups = [
            batchScopePopUp,
            formatPopUp,
            bitratePopUp,
            sampleRatePopUp,
            folderStructurePopUp,
            applyModePopUp,
            templatePresetPopUp
        ] + tokenPopups

        for popUp in popups {
            popUp.bezelStyle = .texturedRounded
            popUp.controlSize = .small
            popUp.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }

        batchScopePopUp.removeAllItems()
        for scope in ConversionBatchScope.allCases {
            batchScopePopUp.addItem(withTitle: scope.title)
            batchScopePopUp.lastItem?.representedObject = scope.rawValue
        }

        formatPopUp.removeAllItems()
        for format in outputFormats {
            formatPopUp.addItem(withTitle: displayName(for: format))
            formatPopUp.lastItem?.representedObject = format.rawValue
        }

        bitratePopUp.removeAllItems()
        for option in bitrateOptions {
            bitratePopUp.addItem(withTitle: option < 0 ? "Auto" : "\(option) kbps")
            bitratePopUp.lastItem?.tag = option
        }

        sampleRatePopUp.removeAllItems()
        for option in sampleRateOptions {
            sampleRatePopUp.addItem(withTitle: option < 0 ? "Source" : "\(option) Hz")
            sampleRatePopUp.lastItem?.tag = option
        }

        folderStructurePopUp.removeAllItems()
        for mode in FolderStructureMode.allCases {
            folderStructurePopUp.addItem(withTitle: mode.title)
            folderStructurePopUp.lastItem?.representedObject = mode.rawValue
        }

        applyModePopUp.removeAllItems()
        for mode in TemplateApplyMode.allCases {
            applyModePopUp.addItem(withTitle: mode.title)
            applyModePopUp.lastItem?.representedObject = mode.rawValue
        }

        templatePresetPopUp.removeAllItems()
        for preset in TemplatePreset.allCases {
            templatePresetPopUp.addItem(withTitle: preset.title)
            templatePresetPopUp.lastItem?.representedObject = preset.rawValue
        }

        for popup in tokenPopups {
            popup.removeAllItems()
            for token in FolderToken.allCases {
                popup.addItem(withTitle: token.title)
                popup.lastItem?.representedObject = token.rawValue
            }
        }

        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)
        folderStructurePopUp.target = self
        folderStructurePopUp.action = #selector(folderModeChanged)
        templatePresetPopUp.target = self
        templatePresetPopUp.action = #selector(templatePresetChanged)
        tokenPopups.forEach {
            $0.target = self
            $0.action = #selector(tokenOrderChanged)
        }
    }

    private func applyInitialSelection() {
        select(batchScopePopUp, rawValue: initialSelection.batchScope.rawValue)
        select(formatPopUp, rawValue: initialSelection.outputFormat.rawValue)
        bitratePopUp.selectItem(withTag: initialSelection.bitrate ?? -1)
        sampleRatePopUp.selectItem(withTag: initialSelection.sampleRate ?? -1)
        select(folderStructurePopUp, rawValue: initialSelection.folderStructureMode.rawValue)
        select(applyModePopUp, rawValue: initialSelection.applyMode.rawValue)
        select(templatePresetPopUp, rawValue: initialSelection.templatePreset.rawValue)
        applyTokenOrder(normalizeTokenOrder(initialSelection.tokenOrder))
    }

    @objc private func continueAction() {
        onDecision?(buildSelection())
    }

    @objc private func cancelAction() {
        onDecision?(nil)
    }

    @objc private func formatChanged() {
        updateFormatDependentControls()
    }

    @objc private func folderModeChanged() {
        updateTemplateVisibility()
    }

    @objc private func templatePresetChanged() {
        let preset = selectedTemplatePreset()
        if preset != .custom {
            applyTokenOrder(normalizeTokenOrder(preset.defaultTokenOrder))
        }
        updateTemplateVisibility()
    }

    @objc private func tokenOrderChanged() {
        applyTokenOrder(normalizeTokenOrder(selectedCustomTokenOrder()))
    }

    private func buildSelection() -> ConversionOptionsSelection {
        ConversionOptionsSelection(
            batchScope: selectedBatchScope(),
            outputFormat: selectedOutputFormat(),
            bitrate: selectedBitrate(),
            sampleRate: selectedSampleRate(),
            folderStructureMode: selectedFolderStructureMode(),
            applyMode: selectedApplyMode(),
            templatePreset: selectedTemplatePreset(),
            tokenOrder: normalizeTokenOrder(selectedCustomTokenOrder())
        )
    }

    private func updateFormatDependentControls() {
        let format = selectedOutputFormat()
        bitratePopUp.isEnabled = !isLosslessFormat(format)
        if isLosslessFormat(format) {
            bitratePopUp.selectItem(withTag: -1)
        }
    }

    private func updateTemplateVisibility() {
        let metadataMode = selectedFolderStructureMode() == .metadataTemplate
        templateSection.isHidden = !metadataMode
        applyModePopUp.isEnabled = metadataMode

        let customMode = selectedTemplatePreset() == .custom
        customTokenSection.isHidden = !metadataMode || !customMode
    }

    private func selectedBatchScope() -> ConversionBatchScope {
        let raw = batchScopePopUp.selectedItem?.representedObject as? Int ?? ConversionBatchScope.selectedTracks.rawValue
        return ConversionBatchScope(rawValue: raw) ?? .selectedTracks
    }

    private func selectedOutputFormat() -> OutputFormat {
        let raw = formatPopUp.selectedItem?.representedObject as? String ?? OutputFormat.aac.rawValue
        return OutputFormat(rawValue: raw) ?? .aac
    }

    private func selectedBitrate() -> Int? {
        let tag = bitratePopUp.selectedTag()
        return tag > 0 ? tag : nil
    }

    private func selectedSampleRate() -> Int? {
        let tag = sampleRatePopUp.selectedTag()
        return tag > 0 ? tag : nil
    }

    private func selectedFolderStructureMode() -> FolderStructureMode {
        let raw = folderStructurePopUp.selectedItem?.representedObject as? String ?? FolderStructureMode.sourceRelative.rawValue
        return FolderStructureMode(rawValue: raw) ?? .sourceRelative
    }

    private func selectedApplyMode() -> TemplateApplyMode {
        let raw = applyModePopUp.selectedItem?.representedObject as? String ?? TemplateApplyMode.applyAll.rawValue
        return TemplateApplyMode(rawValue: raw) ?? .applyAll
    }

    private func selectedTemplatePreset() -> TemplatePreset {
        let raw = templatePresetPopUp.selectedItem?.representedObject as? String ?? TemplatePreset.artistYearAlbum.rawValue
        return TemplatePreset(rawValue: raw) ?? .artistYearAlbum
    }

    private func selectedCustomTokenOrder() -> [FolderToken] {
        tokenPopups.compactMap { popup in
            let raw = popup.selectedItem?.representedObject as? String ?? FolderToken.disabled.rawValue
            return FolderToken(rawValue: raw)
        }
    }

    private func applyTokenOrder(_ order: [FolderToken]) {
        for (index, token) in order.enumerated() where index < tokenPopups.count {
            select(tokenPopups[index], rawValue: token.rawValue)
        }
    }

    private func normalizeTokenOrder(_ order: [FolderToken]) -> [FolderToken] {
        var normalized: [FolderToken] = []
        var used: Set<FolderToken> = []
        let nonDisabledPool: [FolderToken] = [.year, .albumArtist, .album, .compilation]

        for token in order.prefix(tokenPopups.count) {
            if token == .disabled {
                normalized.append(.disabled)
                continue
            }

            if used.insert(token).inserted {
                normalized.append(token)
            } else if let fallback = nonDisabledPool.first(where: { !used.contains($0) }) {
                normalized.append(fallback)
                used.insert(fallback)
            } else {
                normalized.append(.disabled)
            }
        }

        while normalized.count < tokenPopups.count {
            normalized.append(.disabled)
        }

        return normalized
    }

    private func select(_ popUp: NSPopUpButton, rawValue: String) {
        for item in popUp.itemArray where (item.representedObject as? String) == rawValue {
            popUp.select(item)
            return
        }
    }

    private func select(_ popUp: NSPopUpButton, rawValue: Int) {
        for item in popUp.itemArray where (item.representedObject as? Int) == rawValue {
            popUp.select(item)
            return
        }
    }

    private func isLosslessFormat(_ format: OutputFormat) -> Bool {
        switch format {
        case .alac, .flac, .wav, .aiff:
            return true
        case .mp3, .aac, .ogg, .opus:
            return false
        }
    }

    private func displayName(for format: OutputFormat) -> String {
        switch format {
        case .mp3:
            return "MP3"
        case .aac:
            return "AAC (M4A)"
        case .alac:
            return "ALAC (M4A)"
        case .flac:
            return "FLAC"
        case .wav:
            return "WAV"
        case .aiff:
            return "AIFF"
        case .ogg:
            return "Ogg Vorbis"
        case .opus:
            return "Opus"
        }
    }
}
