import Foundation

/// What the theme editor offers when the owner switches between Simple and Advanced.
public enum ThemeEditorModeRules {
    public enum Mode: Sendable { case simple, advanced }
    public enum Crossing: Sendable { case copy, convert, cancel }

    /// Simple to Advanced may convert the theme in place (it keeps every token it
    /// wrote). Advanced to Simple never converts: Simple would overwrite hand-made
    /// colours, so only a copy or nothing is offered.
    public static func crossings(from mode: Mode) -> [Crossing] {
        switch mode {
        case .simple: return [.copy, .convert, .cancel]
        case .advanced: return [.copy, .cancel]
        }
    }

    public static func mode(of theme: ThemeDefinition) -> Mode {
        theme.simple != nil ? .simple : .advanced
    }
}
