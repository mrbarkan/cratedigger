/// Which message an empty browser shows. An empty Prep Crate or an empty crate
/// is not "no library loaded", and saying so sent people off to re-open folders.
public enum BrowserEmptyKind: Equatable, Sendable {
    case noLibrary
    case disconnected
    case prepCrate
    case emptyCrate(name: String)

    /// Core cannot import the app's `LibrarySource`, so this mirrors only the
    /// cases this decision needs.
    public enum Source: Equatable, Sendable {
        case localAll
        case localCrate(name: String)
        case prepCrate
        case other
    }

    public static func resolve(source: Source, disconnected: Bool) -> BrowserEmptyKind {
        switch source {
        case .localAll:              return disconnected ? .disconnected : .noLibrary
        case .localCrate(let name):  return disconnected ? .disconnected : .emptyCrate(name: name)
        case .prepCrate:             return .prepCrate
        case .other:                 return .noLibrary
        }
    }
}
