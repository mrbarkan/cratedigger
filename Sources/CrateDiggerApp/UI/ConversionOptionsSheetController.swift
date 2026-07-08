import AppKit
import CrateDiggerCore
import SwiftUI

enum ConversionBatchScope: Int, Codable, CaseIterable {
    case selectedTracks
    case currentAlbum
    case allLoadedTracks

    var title: String {
        switch self {
        case .selectedTracks:
            return "Selected Tracks"
        case .currentAlbum:
            return "Current Album"
        case .allLoadedTracks:
            return "All Loaded Tracks"
        }
    }
}

struct ConversionOptionsSelection: Codable {
    var batchScope: ConversionBatchScope
    var outputFormat: OutputFormat
    var bitrate: Int?
    var sampleRate: Int?
    var artworkMaxDimension: Int?
    var folderStructureMode: FolderStructureMode
    var applyMode: TemplateApplyMode
    var templatePreset: TemplatePreset
    var tokenOrder: [FolderToken]
    /// Custom folder-pattern separators, aligned to `tokenOrder` (separator after
    /// token i). Empty = every gap is a folder break. See `FolderPatternEditor`.
    var separators: [FolderSeparator] = []
}

extension ConversionOptionsSelection {
    /// Back-compatible decode: selections persisted before `separators` existed
    /// omit the key and decode as `[]` (all-`/`, unchanged). Placing this in an
    /// extension keeps the synthesized memberwise initializer available.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batchScope = try c.decode(ConversionBatchScope.self, forKey: .batchScope)
        outputFormat = try c.decode(OutputFormat.self, forKey: .outputFormat)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate)
        artworkMaxDimension = try c.decodeIfPresent(Int.self, forKey: .artworkMaxDimension)
        folderStructureMode = try c.decode(FolderStructureMode.self, forKey: .folderStructureMode)
        applyMode = try c.decode(TemplateApplyMode.self, forKey: .applyMode)
        templatePreset = try c.decode(TemplatePreset.self, forKey: .templatePreset)
        tokenOrder = try c.decode([FolderToken].self, forKey: .tokenOrder)
        separators = try c.decodeIfPresent([FolderSeparator].self, forKey: .separators) ?? []
    }
}

final class ConversionOptionsSheetController: ThemedSheetHostingController {
    var onDecision: ((ConversionOptionsSelection?) -> Void)?

    private let outputFormats: [OutputFormat]
    private let bitrateOptions: [Int]
    private let sampleRateOptions: [Int]
    private let initialSelection: ConversionOptionsSelection

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
        let rootView = ConversionOptionsSheetView(
            initialSelection: initialSelection,
            outputFormats: outputFormats,
            bitrateOptions: bitrateOptions,
            sampleRateOptions: sampleRateOptions
        ) { [weak self] selection in
            self?.onDecision?(selection)
        }

        setThemedRoot(rootView)
    }
}
