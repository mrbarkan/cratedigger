import AppKit
import CrateDiggerCore
import SwiftUI

/// What the conversion acts on — always something you can point at, never the
/// whole library.
///
/// It used to include "All Loaded Tracks", which made the queue a live
/// projection of the current source: thousands of tracks appeared in the Patch
/// Bay that nobody had put there, and one press of CONVERT would have acted on
/// all of them. The three that remain are all deliberate: a queue you filled, a
/// staging crate you filled, or what you have selected right now.
///
/// Raw values are fresh so a selection saved under the old cases can't be
/// mistaken for one of these; anything unrecognised decodes to `.queue`, which
/// is empty until you add to it.
enum ConversionBatchScope: Int, Codable, CaseIterable {
    /// Tracks explicitly added with "Add to Convert Queue".
    case queue = 10
    /// The Prep Crate — the staging area newly scanned folders land in.
    case prep = 11
    /// Whatever is selected in the browser right now.
    case selection = 12

    var title: String {
        switch self {
        case .queue:     return "Convert Queue"
        case .prep:      return "Prep Crate"
        case .selection: return "Selection"
        }
    }

    /// One word where the full title would truncate — the Patch Bay's queue
    /// header shares its line with a count, a duration and a key.
    var shortTitle: String {
        switch self {
        case .queue:     return "Queue"
        case .prep:      return "Prep"
        case .selection: return "Selection"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        // A retired case must not silently become a big one — fall back to the
        // scope that converts nothing until the user picks.
        self = ConversionBatchScope(rawValue: raw) ?? .queue
    }
}

struct ConversionOptionsSelection: Codable {
    var batchScope: ConversionBatchScope
    var outputFormat: OutputFormat
    var bitrate: Int?
    var sampleRate: Int?
    /// How album art is carried into the output. Previously inferred from
    /// whether `artworkMaxDimension` was set, which made "keep the original art
    /// but cap its size" and "drop the art" impossible to express.
    var artworkMode: ArtworkMode = .preserve
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
        // Selections saved before the mode existed encoded it in the dimension.
        artworkMode = try c.decodeIfPresent(ArtworkMode.self, forKey: .artworkMode)
            ?? (artworkMaxDimension == nil ? .preserve : .compatReembed)
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
