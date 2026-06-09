import AppKit
import CrateDiggerCore
import SwiftUI

enum ConversionBatchScope: Int, CaseIterable {
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

struct ConversionOptionsSelection {
    var batchScope: ConversionBatchScope
    var outputFormat: OutputFormat
    var bitrate: Int?
    var sampleRate: Int?
    var artworkMaxDimension: Int?
    var folderStructureMode: FolderStructureMode
    var applyMode: TemplateApplyMode
    var templatePreset: TemplatePreset
    var tokenOrder: [FolderToken]
}

final class ConversionOptionsSheetController: NSViewController {
    var onDecision: ((ConversionOptionsSelection?) -> Void)?

    private let outputFormats: [OutputFormat]
    private let bitrateOptions: [Int]
    private let sampleRateOptions: [Int]
    private let initialSelection: ConversionOptionsSelection
    private var hostingController: NSViewController?

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

        let themed = ThemedSheetWrapper { rootView }
        let hostingController = NSHostingController(rootView: themed)
        self.hostingController = hostingController
        addChild(hostingController)
        view = hostingController.view
    }
}
