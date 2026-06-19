import Foundation

public struct CDTrack: Sendable, Identifiable, Hashable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let title: String
    public let trackNumber: Int

    public init(fileURL: URL, title: String, trackNumber: Int) {
        self.fileURL = fileURL
        self.title = title
        self.trackNumber = trackNumber
    }
}

public struct AudioCDInfo: Sendable, Identifiable, Hashable {
    public var id: String { volumeURL.path }
    public let volumeURL: URL
    public let name: String
    public let tracks: [CDTrack]

    public init(volumeURL: URL, name: String, tracks: [CDTrack]) {
        self.volumeURL = volumeURL
        self.name = name
        self.tracks = tracks
    }
}

public final class CDRipperService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func detectAudioCDs() -> [AudioCDInfo] {
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        guard let contents = try? fileManager.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.volumeNameKey]) else {
            return []
        }

        var cds: [AudioCDInfo] = []
        for url in contents {
            guard let files = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                continue
            }
            
            let aiffFiles = files.filter { $0.pathExtension.lowercased() == "aiff" }
            guard !aiffFiles.isEmpty else {
                continue
            }
            
            let tracks = aiffFiles.compactMap { fileURL -> CDTrack? in
                let name = fileURL.deletingPathExtension().lastPathComponent
                let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.first
                let trackNum = digits.flatMap { Int($0) } ?? 1
                return CDTrack(fileURL: fileURL, title: name, trackNumber: trackNum)
            }.sorted { $0.trackNumber < $1.trackNumber }

            let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            cds.append(AudioCDInfo(volumeURL: url, name: volumeName, tracks: tracks))
        }
        return cds
    }
}
