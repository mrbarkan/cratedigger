import AppKit
import QuartzCore

enum ModernRetroTheme {
    enum StatusTone {
        case neutral
        case info
        case success
        case warning
        case error
    }

    static let surfaceBase = NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    static let surfaceElevated = NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 0.96)
    static let listOdd = NSColor(calibratedRed: 0.985, green: 0.986, blue: 0.992, alpha: 1)
    static let listEven = NSColor(calibratedRed: 0.962, green: 0.968, blue: 0.98, alpha: 1)
    static let separator = NSColor(calibratedRed: 0.78, green: 0.8, blue: 0.84, alpha: 1)
    static let textPrimary = NSColor(calibratedRed: 0.09, green: 0.1, blue: 0.12, alpha: 1)
    static let textSecondary = NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.43, alpha: 1)

    static let accentInfo = NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.96, alpha: 1)
    static let accentSuccess = NSColor(calibratedRed: 0.14, green: 0.66, blue: 0.42, alpha: 1)
    static let accentWarning = NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.18, alpha: 1)
    static let accentError = NSColor(calibratedRed: 0.88, green: 0.24, blue: 0.2, alpha: 1)
    static let indicatorIdle = NSColor(calibratedRed: 0.67, green: 0.7, blue: 0.76, alpha: 1)
    static let indicatorInfo = accentInfo
    static let indicatorSuccess = accentSuccess
    static let indicatorWarning = accentWarning
    static let indicatorError = accentError

    static let toolbarHeight: CGFloat = 84
    static let buttonHeight: CGFloat = 30
    static let buttonCornerRadius: CGFloat = 10
    static let toolbarPrimaryButtonWidth: CGFloat = 128
    static let toolbarPrimaryButtonHeight: CGFloat = buttonHeight
    static let toolbarClusterLeadingInset: CGFloat = 18
    static let toolbarClusterSpacing: CGFloat = 16
    static let activityPulseDuration: TimeInterval = 0.75
    static let contentInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    static let sectionSpacing: CGFloat = 12

    private static let primaryButtonBaseLayer = "ModernRetroPrimaryButtonBase"
    private static let primaryButtonGlossLayer = "ModernRetroPrimaryButtonGloss"
    private static let primaryButtonBorderLayer = "ModernRetroPrimaryButtonBorder"
    private static let secondaryButtonBaseLayer = "ModernRetroSecondaryButtonBase"
    private static let secondaryButtonGlossLayer = "ModernRetroSecondaryButtonGloss"
    private static let secondaryButtonBorderLayer = "ModernRetroSecondaryButtonBorder"

    static func applyChromeMaterial(to view: NSVisualEffectView) {
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
        view.layer?.masksToBounds = true
    }

    static func stylePrimaryActionButton(_ button: NSButton, title: String, minWidth: CGFloat) {
        button.title = title
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = textPrimary
        button.wantsLayer = true
        button.layer?.cornerRadius = buttonCornerRadius
        button.layer?.masksToBounds = false
        installButtonLayers(
            button,
            baseName: primaryButtonBaseLayer,
            glossName: primaryButtonGlossLayer,
            borderName: primaryButtonBorderLayer,
            fillColor: accentInfo.withAlphaComponent(0.2)
        )
        upsertConstraint(button, id: "ModernRetroButtonHeight", attribute: .height, constant: toolbarPrimaryButtonHeight)
        upsertConstraint(button, id: "ModernRetroButtonWidth", attribute: .width, constant: minWidth)
    }

    static func styleSecondaryButton(_ button: NSButton) {
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = textPrimary
        button.wantsLayer = true
        button.layer?.cornerRadius = buttonCornerRadius
        button.layer?.masksToBounds = false
        installButtonLayers(
            button,
            baseName: secondaryButtonBaseLayer,
            glossName: secondaryButtonGlossLayer,
            borderName: secondaryButtonBorderLayer,
            fillColor: NSColor.white.withAlphaComponent(0.45)
        )
    }

    static func updateButtonLayers(_ button: NSButton) {
        guard let layers = button.layer?.sublayers else { return }
        let bounds = button.bounds
        for layer in layers where layer.name == primaryButtonBaseLayer
            || layer.name == primaryButtonGlossLayer
            || layer.name == primaryButtonBorderLayer
            || layer.name == secondaryButtonBaseLayer
            || layer.name == secondaryButtonGlossLayer
            || layer.name == secondaryButtonBorderLayer {
            layer.frame = bounds
            layer.cornerRadius = buttonCornerRadius
        }

        if let base = layers.first(where: { $0.name == primaryButtonBaseLayer }) {
            base.backgroundColor = button.isEnabled
                ? accentInfo.withAlphaComponent(0.2).cgColor
                : separator.withAlphaComponent(0.18).cgColor
        }

        if let border = layers.first(where: { $0.name == primaryButtonBorderLayer }) {
            border.borderColor = (button.isEnabled ? accentInfo : separator).withAlphaComponent(0.42).cgColor
        }

        if let base = layers.first(where: { $0.name == secondaryButtonBaseLayer }) {
            base.backgroundColor = button.isEnabled
                ? NSColor.white.withAlphaComponent(0.45).cgColor
                : NSColor.white.withAlphaComponent(0.3).cgColor
        }

        if let border = layers.first(where: { $0.name == secondaryButtonBorderLayer }) {
            border.borderColor = separator.withAlphaComponent(button.isEnabled ? 0.56 : 0.3).cgColor
        }

        button.contentTintColor = button.isEnabled ? textPrimary : textSecondary.withAlphaComponent(0.65)
    }

    static func stylePopUp(_ popUp: NSPopUpButton) {
        popUp.bezelStyle = .texturedRounded
        popUp.controlSize = .small
        popUp.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    static func styleListContainer(scrollView: NSScrollView, tableView: NSTableView) {
        tableView.backgroundColor = listEven
        tableView.gridColor = separator.withAlphaComponent(0.35)

        scrollView.drawsBackground = true
        scrollView.backgroundColor = listEven
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = listEven.cgColor
    }

    static func drawListRowBackground(_ row: Int, in dirtyRect: NSRect) {
        let fill = row % 2 == 0 ? listEven : listOdd
        fill.setFill()
        dirtyRect.fill()
    }

    static func drawListRowSelection(in dirtyRect: NSRect) {
        let inset = dirtyRect.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 7, yRadius: 7)
        accentInfo.withAlphaComponent(0.8).setFill()
        path.fill()
        separator.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func statusColor(for tone: StatusTone) -> NSColor {
        switch tone {
        case .neutral:
            return textSecondary
        case .info:
            return accentInfo
        case .success:
            return accentSuccess
        case .warning:
            return accentWarning
        case .error:
            return accentError
        }
    }

    private static func installButtonLayers(
        _ button: NSButton,
        baseName: String,
        glossName: String,
        borderName: String,
        fillColor: NSColor
    ) {
        button.layer?.sublayers?.removeAll(where: { layer in
            if let name = layer.name, name == primaryButtonBaseLayer
                || name == primaryButtonGlossLayer
                || name == primaryButtonBorderLayer
                || name == secondaryButtonBaseLayer
                || name == secondaryButtonGlossLayer
                || name == secondaryButtonBorderLayer {
                layer.removeFromSuperlayer()
                return true
            }
            return false
        })

        let base = CALayer()
        base.name = baseName
        base.backgroundColor = fillColor.cgColor
        base.cornerRadius = buttonCornerRadius
        base.frame = button.bounds

        let gloss = CAGradientLayer()
        gloss.name = glossName
        gloss.colors = [
            NSColor.white.withAlphaComponent(0.24).cgColor,
            NSColor.clear.cgColor
        ]
        gloss.locations = [0, 1]
        gloss.cornerRadius = buttonCornerRadius
        gloss.frame = button.bounds

        let border = CALayer()
        border.name = borderName
        border.borderColor = separator.withAlphaComponent(0.75).cgColor
        border.borderWidth = 1
        border.cornerRadius = buttonCornerRadius
        border.frame = button.bounds

        button.layer?.insertSublayer(base, at: 0)
        button.layer?.insertSublayer(gloss, above: base)
        button.layer?.insertSublayer(border, above: gloss)
        updateButtonLayers(button)
    }

    private static func upsertConstraint(
        _ button: NSButton,
        id: String,
        attribute: NSLayoutConstraint.Attribute,
        constant: CGFloat
    ) {
        let existing = button.constraints.filter { constraint in
            constraint.identifier == id && constraint.firstAttribute == attribute
        }
        for constraint in existing {
            constraint.isActive = false
            button.removeConstraint(constraint)
        }

        let constraint: NSLayoutConstraint
        if attribute == .width {
            constraint = button.widthAnchor.constraint(equalToConstant: constant)
        } else {
            constraint = button.heightAnchor.constraint(equalToConstant: constant)
        }
        constraint.identifier = id
        constraint.isActive = true
    }
}
