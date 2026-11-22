import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CrateDiggerCore

/// Stands in for the network in every artist-picture test: answers each URL
/// from a table and records what was asked, and when. A URL with no answer
/// fails with a 404, so a test never reaches a real service by accident.
final class FakePictureFetcher: ArtistPictureFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: [Result<Data, Error>]]
    private var recorded: [(url: URL, at: ContinuousClock.Instant)] = []

    init(_ answers: [URL: Result<Data, Error>] = [:]) {
        self.answers = answers.mapValues { [$0] }
    }

    /// Answers `url` with each result in turn; the last one repeats.
    func answer(_ url: URL, with results: [Result<Data, Error>]) {
        lock.lock()
        defer { lock.unlock() }
        answers[url] = results
    }

    func answer(_ url: URL, json: String) {
        answer(url, with: [.success(Data(json.utf8))])
    }

    func answer(_ url: URL, data: Data) {
        answer(url, with: [.success(data)])
    }

    var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.url)
    }

    var requestTimes: [ContinuousClock.Instant] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.at)
    }

    func data(from url: URL) async throws -> Data {
        let result: Result<Data, Error> = {
            lock.lock()
            defer { lock.unlock() }
            recorded.append((url, ContinuousClock.now))
            guard var queue = answers[url], let first = queue.first else {
                return .failure(ArtistPictureSourceError.http(404))
            }
            if queue.count > 1 {
                queue.removeFirst()
                answers[url] = queue
            }
            return first
        }()
        return try result.get()
    }

    /// A real JPEG of `width` × `height` in one colour, big enough for
    /// `ArtistPictureImage.prepare` to accept at the default 500 px.
    static func jpeg(width: Int = 500, height: Int = 500, red: CGFloat = 0.8) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
