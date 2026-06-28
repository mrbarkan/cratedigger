import AppKit
import SwiftUI

final class ConversionSummarySheetController: ThemedSheetHostingController {
    var onClose: (() -> Void)?

    private let report: ConversionReport

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

        setThemedRoot(rootView)
    }
}
