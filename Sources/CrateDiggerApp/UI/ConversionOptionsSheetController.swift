import AppKit
import CrateDiggerCore
import SwiftUI

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
    let artworkMaxDimension: Int?
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
    private var hostingController: NSHostingController<ConversionOptionsSheetView>?

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

        let hostingController = NSHostingController(rootView: rootView)
        self.hostingController = hostingController
        addChild(hostingController)
        view = hostingController.view
    }
}
