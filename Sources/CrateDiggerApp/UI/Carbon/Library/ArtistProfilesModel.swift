import CrateDiggerCore
import Foundation

/// The artist profiles as the views show them, and which artists a lookup
/// is running for, apart from `LibraryViewModel`'s published state: only
/// the artist page, the Edit sheet and the photo viewer observe this, so a
/// background lookup landing redraws those and nothing else. Published only
/// when something actually changed (`LibraryViewModel.reloadArtistProfiles`
/// compares off the main actor).
@MainActor
final class ArtistProfilesModel: ObservableObject {
    /// Every artist profile, by folded key (`PodBoxArtName.folded`), as the
    /// store last read off the main actor.
    @Published private(set) var profiles: [String: ArtistProfile] = [:]
    /// Folded keys of the artists a lookup (the owner's or the worker's) is
    /// running for.
    @Published private(set) var running: Set<String> = []

    func profile(named name: String) -> ArtistProfile? {
        profiles[PodBoxArtName.folded(name)]
    }

    func isLookingUp(_ name: String) -> Bool {
        running.contains(PodBoxArtName.folded(name))
    }

    func publish(_ profiles: [String: ArtistProfile]) {
        self.profiles = profiles
    }

    func setRunning(_ keys: Set<String>) {
        if keys != running { running = keys }
    }
}
