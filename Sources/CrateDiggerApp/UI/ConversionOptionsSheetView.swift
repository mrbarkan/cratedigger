import AppKit
import CrateDiggerCore
import SwiftUI

struct ConversionOptionsSheetView: View {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversion Options")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textPrimary))

            Text("Configure one conversion plan for this run. These settings are the source of truth for the files about to be converted.")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textSecondary))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    onDecision(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    onDecision(buildSelection())
                }
                .keyboardShortcut(.defaultAction)
                .tint(Color(nsColor: ModernRetroTheme.accentInfo))
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: ModernRetroTheme.surfaceBase))
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
                }

                field(title: "Format") {
                    Picker("Format", selection: $outputFormat) {
                        ForEach(outputFormats, id: \.self) { format in
                            Text(displayName(for: format)).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                }

                field(title: "Bitrate") {
                    Picker("Bitrate", selection: $bitrateTag) {
                        ForEach(bitrateOptions, id: \.self) { option in
                            Text(option < 0 ? "Auto" : "\(option) kbps").tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isLosslessFormat(outputFormat))
                }

                field(title: "Sample Rate") {
                    Picker("Sample Rate", selection: $sampleRateTag) {
                        ForEach(sampleRateOptions, id: \.self) { option in
                            Text(option < 0 ? "Source" : "\(option) Hz").tag(option)
                        }
                    }
                    .pickerStyle(.menu)
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
                }

                field(title: "Apply Mode") {
                    Picker("Apply Mode", selection: $applyMode) {
                        ForEach(TemplateApplyMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isMetadataTemplateMode)
                }
            }

            Text("Use 'Review album folders' when you want to confirm each album destination before conversion starts.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textSecondary))
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
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textSecondary))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textSecondary))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color(nsColor: ModernRetroTheme.surfaceElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(nsColor: ModernRetroTheme.separator).opacity(0.35), lineWidth: 1)
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
