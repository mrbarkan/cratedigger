import AppKit
import CrateDiggerCore
import SwiftUI

struct ConversionOptionsSheetView: View {
    @Environment(\.carbon) private var theme

    private static let tokenCount = 5

    let outputFormats: [OutputFormat]
    let bitrateOptions: [Int]
    let sampleRateOptions: [Int]
    let onDecision: (ConversionOptionsSelection?) -> Void

    @State private var batchScope: ConversionBatchScope
    @State private var outputFormat: OutputFormat
    @State private var bitrateTag: Int
    @State private var sampleRateTag: Int
    @State private var artworkSizeRawValue: String
    @State private var folderStructureMode: FolderStructureMode
    @State private var applyMode: TemplateApplyMode
    @State private var templatePreset: TemplatePreset
    @State private var tokenOrder: [FolderToken]

    init(
        initialSelection: ConversionOptionsSelection,
        outputFormats: [OutputFormat],
        bitrateOptions: [Int],
        sampleRateOptions: [Int],
        onDecision: @escaping (ConversionOptionsSelection?) -> Void
    ) {
        self.outputFormats = outputFormats
        self.bitrateOptions = bitrateOptions
        self.sampleRateOptions = sampleRateOptions
        self.onDecision = onDecision

        _batchScope = State(initialValue: initialSelection.batchScope)
        _outputFormat = State(initialValue: initialSelection.outputFormat)
        _bitrateTag = State(initialValue: initialSelection.bitrate ?? -1)
        _sampleRateTag = State(initialValue: initialSelection.sampleRate ?? -1)
        _artworkSizeRawValue = State(initialValue: initialSelection.artworkMaxDimension.map(String.init) ?? "original")
        _folderStructureMode = State(initialValue: initialSelection.folderStructureMode)
        _applyMode = State(initialValue: initialSelection.applyMode)
        _templatePreset = State(initialValue: initialSelection.templatePreset)
        _tokenOrder = State(initialValue: Self.normalizeTokenOrder(initialSelection.tokenOrder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeAndFormatSection
                    fileNamingSection

                    if isMetadataTemplateMode {
                        folderStrategySection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .padding(.trailing, 4)
            }

            actionBar
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(minWidth: 780, minHeight: 540)
        .background(theme.chassis)
        .onAppear {
            tokenOrder = Self.normalizeTokenOrder(tokenOrder)
            if isLosslessFormat(outputFormat) {
                bitrateTag = -1
            }
        }
        .onChange(of: outputFormat) { newValue in
            if isLosslessFormat(newValue) {
                bitrateTag = -1
            }
        }
        .onChange(of: templatePreset) { newValue in
            if newValue != .custom {
                tokenOrder = Self.normalizeTokenOrder(newValue.defaultTokenOrder)
            }
        }
    }

    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("CONVERSION")
                    .font(CarbonFont.mono(10, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(theme.orange)
                Rectangle()
                    .fill(theme.hair)
                    .frame(height: 1)
            }
            Text("Conversion Options")
                .font(CarbonFont.sans(28, weight: .heavy))
                .foregroundStyle(theme.ink)
            Text("Configure one conversion plan for this run. These settings are the source of truth for the files about to be converted.")
                .font(CarbonFont.mono(12))
                .foregroundStyle(theme.ink2)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            KeyButton(style: .normal, action: { onDecision(nil) }) {
                Text("CANCEL")
                    .font(CarbonFont.mono(10, weight: .bold))
                    .tracking(2)
            }
            .frame(width: 124, height: 38)
            .keyboardShortcut(.cancelAction)

            KeyButton(style: .glowingOrange, action: { onDecision(buildSelection()) }) {
                Text("CONTINUE")
                    .font(CarbonFont.mono(10, weight: .bold))
                    .tracking(2)
            }
            .frame(width: 144, height: 38)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    private var scopeAndFormatSection: some View {
        sectionCard(title: "Scope + Format") {
            twoColumnGrid {
                field(title: "Batch Scope") {
                    Picker("Batch Scope", selection: $batchScope) {
                        ForEach(ConversionBatchScope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                }

                field(title: "Format") {
                    Picker("Format", selection: $outputFormat) {
                        ForEach(outputFormats, id: \.self) { format in
                            Text(displayName(for: format)).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                }

                field(title: "Bitrate") {
                    Picker("Bitrate", selection: $bitrateTag) {
                        ForEach(bitrateOptions, id: \.self) { option in
                            Text(option < 0 ? "Auto" : "\(option) kbps").tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                    .disabled(isLosslessFormat(outputFormat))
                }

                field(title: "Sample Rate") {
                    Picker("Sample Rate", selection: $sampleRateTag) {
                        ForEach(sampleRateOptions, id: \.self) { option in
                            Text(option < 0 ? "Source" : "\(option) Hz").tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                }

                field(title: "Artwork Resize") {
                    Picker("Artwork Resize", selection: $artworkSizeRawValue) {
                        Text("Original").tag("original")
                        Text("300 px").tag("300")
                        Text("600 px").tag("600")
                        Text("1000 px").tag("1000")
                        Text("1400 px").tag("1400")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                }

                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var fileNamingSection: some View {
        sectionCard(title: "File Naming + Structure") {
            twoColumnGrid {
                field(title: "Folder Structure") {
                    Picker("Folder Structure", selection: $folderStructureMode) {
                        ForEach(FolderStructureMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                }

                field(title: "Apply Mode") {
                    Picker("Apply Mode", selection: $applyMode) {
                        ForEach(TemplateApplyMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                    .disabled(!isMetadataTemplateMode)
                }
            }

            Text("Use 'Review album folders' when you want to confirm each album destination before conversion starts.")
                .font(CarbonFont.mono(11, weight: .medium))
                .foregroundStyle(theme.ink3)
        }
    }

    private var folderStrategySection: some View {
        sectionCard(title: "Folder Strategy") {
            VStack(alignment: .leading, spacing: 8) {
                field(title: "Folder Order") {
                    Picker("Folder Order", selection: $templatePreset) {
                        ForEach(TemplatePreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.orange)
                }

                if templatePreset == .custom {
                    field(title: "Token Order") {
                        HStack(spacing: 8) {
                            ForEach(0..<Self.tokenCount, id: \.self) { index in
                                Picker("Token \(index + 1)", selection: tokenBinding(at: index)) {
                                    ForEach(FolderToken.allCases, id: \.self) { token in
                                        Text(token.title).tag(token)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .tint(theme.orange)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private var isMetadataTemplateMode: Bool {
        folderStructureMode == .metadataTemplate
    }

    private func buildSelection() -> ConversionOptionsSelection {
        ConversionOptionsSelection(
            batchScope: batchScope,
            outputFormat: outputFormat,
            bitrate: bitrateTag > 0 ? bitrateTag : nil,
            sampleRate: sampleRateTag > 0 ? sampleRateTag : nil,
            artworkMaxDimension: Int(artworkSizeRawValue),
            folderStructureMode: folderStructureMode,
            applyMode: applyMode,
            templatePreset: templatePreset,
            tokenOrder: Self.normalizeTokenOrder(tokenOrder)
        )
    }

    private func tokenBinding(at index: Int) -> Binding<FolderToken> {
        Binding(
            get: { tokenValue(at: index) },
            set: { newValue in
                var next = tokenOrder
                if next.count < Self.tokenCount {
                    next.append(contentsOf: Array(repeating: .disabled, count: Self.tokenCount - next.count))
                }
                guard next.indices.contains(index) else {
                    return
                }
                next[index] = newValue
                tokenOrder = Self.normalizeTokenOrder(next)
            }
        )
    }

    private func tokenValue(at index: Int) -> FolderToken {
        guard tokenOrder.indices.contains(index) else {
            return .disabled
        }
        return tokenOrder[index]
    }

    private static func normalizeTokenOrder(_ order: [FolderToken]) -> [FolderToken] {
        var normalized: [FolderToken] = []
        var used: Set<FolderToken> = []
        let nonDisabledPool: [FolderToken] = [.year, .albumArtist, .album, .compilation]

        for token in order.prefix(tokenCount) {
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

        while normalized.count < tokenCount {
            normalized.append(.disabled)
        }

        return normalized
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

    @ViewBuilder
    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(CarbonFont.mono(9, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(theme.ink3)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(theme.ink2)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(theme.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(theme.hair.opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func twoColumnGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 120), spacing: 12),
                GridItem(.flexible(minimum: 120), spacing: 12)
            ],
            alignment: .leading,
            spacing: 8,
            content: content
        )
    }
}
