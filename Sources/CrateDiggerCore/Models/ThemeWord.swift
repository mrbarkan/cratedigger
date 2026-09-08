import Foundation

/// What the app calls a theme.
///
/// Winamp called them skins. `Llama '97` is a tribute to Winamp, so while it is
/// the theme in use the app says *skin* — the key on the chassis, the inspector
/// pane, the Appearance menu, the editor. Pick anything else and the word goes
/// back to *theme*.
///
/// One function rather than a flag each call site tests, because the failure
/// mode of an easter egg is a word that is right on the key and wrong three
/// inches away in the pane it opens.
public enum ThemeWord {
    /// The one theme with its own vocabulary. Keyed by id, not by name: a name
    /// is the author's to change, and a fork of Llama is a different skin.
    public static let skinThemeID = "llama-97"

    public static func isSkinVocabulary(themeID: String?) -> Bool {
        themeID == skinThemeID
    }

    /// `text` with every "theme" turned into "skin", keeping the case of the
    /// word it replaces. Returns `text` untouched for every other theme.
    ///
    /// Longest form first: replacing THEME before THEMES would leave the S
    /// stranded on the end of SKIN.
    public static func inflect(_ text: String, themeID: String?) -> String {
        guard isSkinVocabulary(themeID: themeID) else { return text }
        var out = text
        for (theme, skin) in [
            ("THEMES", "SKINS"), ("Themes", "Skins"), ("themes", "skins"),
            ("THEME", "SKIN"),   ("Theme", "Skin"),   ("theme", "skin"),
        ] {
            out = out.replacingOccurrences(of: theme, with: skin)
        }
        return out
    }
}
