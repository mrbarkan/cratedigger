import AppKit
import SwiftUI

final class ConversionSummarySheetController: NSViewController {
    var onClose: (() -> Void)?

    private let report: ConversionReport
    private var hostingController: NSViewController?

    init(report: ConversionReport) {
        self.report = report
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ConversionSummarySheetView(report: report) { [weak self] in
            self?.onClose?()
        }

        let themed = ThemedSheetWrapper { rootView }
        let hostingController = NSHostingController(rootView: themed)
        self.hostingController = hostingController
        addChild(hostingController)
        view = hostingController.view
    }
}
