import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Feeds a progressive HTTP media URL to AVPlayer through **bounded** byte-range
/// requests instead of the open-ended one AVPlayer would issue itself.
///
/// YouTube's `videoplayback` URLs (the DASH audio yt-dlp falls back to whenever
/// HLS formats aren't offered — which, without a GVS PO token, is most VODs)
/// throttle hard on request shape. Measured on one URL:
///
/// ```
/// Range: bytes=0-1048575        ->  16.8 MB/s
/// Range: bytes=1048576-2097151  ->  19.5 MB/s
/// Range: bytes=0-      (open)   ->  32.7 KB/s     <- 500x slower
/// ```
///
/// AVPlayer asks for the whole resource in one open-ended request, so a 129 kbps
/// AAC arrives at barely 2x realtime: tens of seconds to fill the start buffer,
/// then constant stalling. Interposing here turns each of AVPlayer's requests
/// into a sequence of `chunkSize` slices with explicit end offsets, which is the
/// fast path.
///
/// HLS never comes through here — a media playlist is already one bounded
/// request per segment, so `wrapIfProgressive` leaves `.m3u8` URLs alone.
public final class ChunkedStreamLoader: NSObject, AVAssetResourceLoaderDelegate {

    /// Prepended to the real scheme so AVFoundation hands the URL to a delegate
    /// rather than loading it itself. Keeping the original scheme in the string
    /// means `unwrap` needs no state.
    public static let schemePrefix = "cdchunk-"

    /// 4 MiB. Start-up is round-trip bound (AVPlayer wants tens of MB before it
    /// reports `readyToPlay`), so bigger chunks are faster — but only up to a
    /// point. Measured against one `videoplayback` URL:
    ///
    /// ```
    ///  1 MiB -> 10.9 MB/s      8 MiB -> 25.8 MB/s
    ///  4 MiB -> 25.6 MB/s     16 MiB ->  32 KB/s   <- throttle returns
    /// ```
    ///
    /// The cliff sits between 8 and 16 MiB, so this keeps a full 2x of margin
    /// in case YouTube moves it. Raise it only with that measurement re-run.
    public static let defaultChunkSize: Int64 = 4 << 20

    private let chunkSize: Int64
    private let session: URLSession

    /// The delegate callback queue. AVFoundation calls in on this, and the
    /// loader hands work straight to `URLSession`, so a serial queue is enough.
    public let queue = DispatchQueue(label: "com.cratedigger.chunked-stream-loader")

    /// Total resource size, learned from the first `Content-Range`. Only ever
    /// touched on `queue`.
    private var contentLength: Int64?
    private var contentType: String?
    private var inFlight: [ObjectIdentifier: URLSessionDataTask] = [:]

    public init(chunkSize: Int64 = ChunkedStreamLoader.defaultChunkSize,
                session: URLSession = .shared) {
        self.chunkSize = max(1, chunkSize)
        self.session = session
    }

    // MARK: - URL wrapping

    /// Wrap `url` so AVFoundation routes it to this delegate. Returns nil if it
    /// has no scheme, or is already wrapped.
    public static func wrap(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme,
              !scheme.hasPrefix(schemePrefix)
        else { return nil }
        parts.scheme = schemePrefix + scheme
        return parts.url
    }

    /// Recover the real URL from a wrapped one. Returns nil if it isn't wrapped.
    public static func unwrap(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme,
              scheme.hasPrefix(schemePrefix)
        else { return nil }
        parts.scheme = String(scheme.dropFirst(schemePrefix.count))
        return parts.url
    }

    public static func isWrapped(_ url: URL) -> Bool {
        url.scheme?.hasPrefix(schemePrefix) ?? false
    }

    /// Wrap only the URLs that actually benefit: remote progressive media.
    /// Local files and HLS playlists are returned untouched — HLS already
    /// fetches bounded segments, and interposing on it would only add latency
    /// (and break AVPlayer's variant switching).
    public static func wrapIfProgressive(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.pathExtension.lowercased() != "m3u8"
        else { return url }
        return wrap(url) ?? url
    }

    // MARK: - Chunk arithmetic

    /// The next slice to fetch, or nil once `offset` is past `end`.
    /// Both bounds are inclusive, matching HTTP's `Range: bytes=first-last`.
    static func nextChunk(from offset: Int64, through end: Int64, chunkSize: Int64) -> ClosedRange<Int64>? {
        guard offset <= end, chunkSize > 0 else { return nil }
        return offset...min(offset + chunkSize - 1, end)
    }

    /// Parse the total resource size out of a `Content-Range: bytes 0-1/12345`
    /// header. Returns nil for the unsatisfiable `*` form.
    static func totalLength(fromContentRange header: String) -> Int64? {
        guard let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let sourceURL = Self.unwrap(requestURL)
        else { return false }
        serve(loadingRequest, from: sourceURL)
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        queue.async { [weak self] in
            self?.inFlight.removeValue(forKey: key)?.cancel()
        }
    }

    // MARK: - Serving

    /// Satisfy one `AVAssetResourceLoadingRequest`, chunk by chunk. Runs on
    /// `queue`; each chunk's completion re-enters on `queue` and starts the next.
    private func serve(_ request: AVAssetResourceLoadingRequest, from sourceURL: URL) {
        queue.async { [weak self] in
            guard let self else { return }

            // AVFoundation sometimes asks only for content info, with no data
            // request. A 2-byte probe answers that without pulling any media.
            guard let dataRequest = request.dataRequest else {
                self.fetch(sourceURL, range: 0...1, for: request) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let response, _):
                        self.fillContentInformation(request, response: response)
                        request.finishLoading()
                    case .failure(let error):
                        request.finishLoading(with: error)
                    }
                }
                return
            }

            // `currentOffset` is where AVFoundation still needs bytes; it can be
            // ahead of `requestedOffset` when part of the request was already
            // satisfied from an earlier response.
            let start = max(dataRequest.requestedOffset, dataRequest.currentOffset)
            let end: Int64
            if dataRequest.requestsAllDataToEndOfResource {
                // The open-ended case — exactly the one that gets throttled.
                // We can't name the last byte until the first response tells us
                // the total, so aim at the chunk boundary and extend below.
                end = self.contentLength.map { $0 - 1 } ?? (start + self.chunkSize - 1)
            } else {
                end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
            }
            self.pump(request, dataRequest: dataRequest, from: sourceURL, offset: start, end: end)
        }
    }

    /// Fetch one chunk, hand it to AVFoundation, then recurse for the next.
    private func pump(_ request: AVAssetResourceLoadingRequest,
                      dataRequest: AVAssetResourceLoadingDataRequest,
                      from sourceURL: URL,
                      offset: Int64,
                      end: Int64) {
        guard !request.isFinished, !request.isCancelled else { return }
        guard let chunk = Self.nextChunk(from: offset, through: end, chunkSize: chunkSize) else {
            request.finishLoading()
            return
        }

        fetch(sourceURL, range: chunk, for: request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                request.finishLoading(with: error)
            case .success(let response, let data):
                self.fillContentInformation(request, response: response)
                request.dataRequest?.respond(with: data)

                // A 200 means the server ignored our Range and sent the whole
                // body: there is nothing left to ask for, and asking anyway
                // would feed AVFoundation the same bytes twice.
                guard response?.statusCode == 206 else {
                    request.finishLoading()
                    return
                }

                // Now that the total is known, an open-ended request can run to
                // the real last byte rather than stopping at the first chunk.
                var newEnd = end
                if dataRequest.requestsAllDataToEndOfResource, let total = self.contentLength {
                    newEnd = total - 1
                }
                self.pump(request,
                          dataRequest: dataRequest,
                          from: sourceURL,
                          offset: chunk.upperBound + 1,
                          end: newEnd)
            }
        }
    }

    private enum FetchResult {
        case success(HTTPURLResponse?, Data)
        case failure(Error)
    }

    /// googlevideo intermittently 403s an otherwise-good URL, in windows that
    /// last a few seconds — an immediate retry is often still inside the window,
    /// so the delay triples each time (0.3s, 0.9s, 2.7s ≈ 4s of cover). Without
    /// this a blip kills the stream and raises the FIX panel for a transient.
    private static let maxChunkAttempts = 4
    private static let baseRetryDelay: TimeInterval = 0.3

    /// One bounded range GET, retried on transient failure. The completion is
    /// delivered on `queue`.
    private func fetch(_ url: URL,
                       range: ClosedRange<Int64>,
                       for request: AVAssetResourceLoadingRequest,
                       attempt: Int = 1,
                       completion: @escaping (FetchResult) -> Void) {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                            forHTTPHeaderField: "Range")

        let key = ObjectIdentifier(request)
        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.inFlight.removeValue(forKey: key)

                /// Give up on this chunk, or try it again shortly.
                func giveUpOrRetry(_ error: Error) {
                    guard attempt < Self.maxChunkAttempts, !request.isCancelled, !request.isFinished else {
                        completion(.failure(error))
                        return
                    }
                    let delay = Self.baseRetryDelay * pow(3, Double(attempt - 1))
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.fetch(url, range: range, for: request,
                                   attempt: attempt + 1, completion: completion)
                    }
                }

                if let error {
                    // A cancel is our own doing (AVFoundation dropped the
                    // request); don't report it, and don't retry it either.
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    giveUpOrRetry(error)
                    return
                }
                // Feeding a 403/404 body to AVFoundation corrupts the stream and
                // surfaces as an opaque "Operation Stopped" rather than the
                // real cause, so fail loudly here instead.
                let http = response as? HTTPURLResponse
                guard let http, (200...299).contains(http.statusCode) else {
                    giveUpOrRetry(URLError(.badServerResponse,
                                           userInfo: [NSLocalizedDescriptionKey:
                                            "Stream server returned HTTP \(http?.statusCode ?? 0)."]))
                    return
                }
                completion(.success(http, data ?? Data()))
            }
        }
        queue.async { [weak self] in
            self?.inFlight[key] = task
            task.resume()
        }
    }

    /// Populate the content-information request from a response's headers, and
    /// cache the total length for subsequent open-ended requests.
    private func fillContentInformation(_ request: AVAssetResourceLoadingRequest,
                                        response: HTTPURLResponse?) {
        guard let response else { return }

        if contentLength == nil,
           let header = response.value(forHTTPHeaderField: "Content-Range"),
           let total = Self.totalLength(fromContentRange: header) {
            contentLength = total
        }
        if contentType == nil, let mime = response.value(forHTTPHeaderField: "Content-Type") {
            // AVFoundation wants a UTI here, not a MIME type.
            contentType = UTType(mimeType: mime.components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespaces))?.identifier
        }

        guard let info = request.contentInformationRequest else { return }
        info.isByteRangeAccessSupported = true
        info.contentType = contentType
        if let contentLength { info.contentLength = contentLength }
    }
}
