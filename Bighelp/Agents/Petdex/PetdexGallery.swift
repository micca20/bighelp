import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One pet from the petdex gallery (https://petdex.dev), as Hermes's
/// `pet.gallery` or the public manifest lists it.
struct PetdexPet: Identifiable, Equatable, Sendable {
    let slug: String
    let displayName: String
    /// The full animation sheet. Empty for pets hatched on the host.
    let spritesheetURL: URL?
    var installed = false
    var curated = false

    var id: String { slug }
}

/// Limits for everything petdex sends: names, counts, downloads and images.
enum PetdexPolicy {
    static let manifestURL = URL(string: "https://petdex.dev/api/manifest")!
    static let maximumPets = 10_000
    static let maximumManifestBytes = 8_000_000
    static let maximumSheetBytes = 6_000_000
    /// A pet's preview strip: its first idle frames (1152×208, about 50 KB).
    static let maximumPreviewBytes = 1_000_000
    static let maximumThumbnailBytes = 600_000
    static let maximumSheetDimension = 4_096
    /// One frame of a petdex sheet (8 columns × 9 rows of 192×208).
    static let frameWidth = 192
    static let frameHeight = 208
    static let requestTimeout: TimeInterval = 20

    /// Only petdex's own hosts, over https, ever get a request from the app.
    static func isPetdexURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return host == "petdex.dev" || host.hasSuffix(".petdex.dev")
    }

    /// petdex's small preview strip for a pet, about 40 times smaller than its
    /// full sheet. Only plain slugs make an address.
    static func previewURL(slug: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (1...128).contains(slug.utf8.count), slug.unicodeScalars.allSatisfy(allowed.contains),
              slug.first != "-", slug.first != "_" else { return nil }
        return URL(string: "https://assets.petdex.dev/pets/\(slug)/preview.webp")
    }

    static func pet(slug: String?, name: String?, sheet: String?, installed: Bool = false, curated: Bool? = nil) -> PetdexPet? {
        guard let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty, slug.utf8.count <= 128,
              !slug.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var displayName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty || displayName.utf8.count > 200
            || displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            displayName = slug
        }
        let url = sheet.flatMap { $0.utf8.count <= 2_048 ? URL(string: $0) : nil }
        let sheetURL = isPetdexURL(url) ? url : nil
        return PetdexPet(slug: slug, displayName: displayName, spritesheetURL: sheetURL, installed: installed,
                         curated: curated ?? (sheetURL?.path().contains("/curated/") ?? false))
    }

    /// Hermes's `pet.gallery` reply. Unknown keys are ignored and bad rows skipped.
    static func pets(fromHost payload: [String: BighelpJSONValue]) -> [PetdexPet] {
        guard let rows = payload["pets"]?.array else { return [] }
        var seen = Set<String>()
        return rows.prefix(maximumPets).compactMap { row -> PetdexPet? in
            guard let fields = row.object,
                  let pet = pet(slug: fields["slug"]?.string, name: fields["displayName"]?.string,
                                sheet: fields["spritesheetUrl"]?.string,
                                installed: fields["installed"]?.boolean ?? false,
                                curated: fields["curated"]?.boolean),
                  seen.insert(pet.slug).inserted else { return nil }
            return pet
        }
    }

    private struct Manifest: Decodable {
        struct Row: Decodable {
            let slug: String?
            let displayName: String?
            let spritesheetUrl: String?
        }
        let pets: [Row]
    }

    /// The public manifest (`{"pets": [{"slug", "displayName", "spritesheetUrl", …}]}`).
    static func pets(fromManifest data: Data) throws -> [PetdexPet] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        var seen = Set<String>()
        return manifest.pets.prefix(maximumPets).compactMap { row -> PetdexPet? in
            guard let pet = pet(slug: row.slug, name: row.displayName, sheet: row.spritesheetUrl),
                  pet.spritesheetURL != nil, seen.insert(pet.slug).inserted else { return nil }
            return pet
        }
    }

    /// Search like Hermes Desktop: the name or the slug contains the words;
    /// installed pets first, then petdex's hand-picked ones.
    static func ranked(_ pets: [PetdexPet], query: String) -> [PetdexPet] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = words.isEmpty ? pets : pets.filter {
            $0.displayName.lowercased().contains(words) || $0.slug.contains(words)
        }
        func rank(_ pet: PetdexPet) -> Int { pet.installed ? 0 : pet.curated ? 1 : 2 }
        return matches.enumerated()
            .sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }
}

enum PetdexError: Error, Equatable {
    case unsupported
    case invalidImage
    case tooLarge
    case blockedAddress
}

/// Frame 0 of a sheet, checked and cut out; and that frame as a crisp avatar.
enum PetdexSprite {
    /// A `pet.thumb` data URI: a small PNG, checked before it's drawn.
    static func thumbnail(fromDataURI uri: String) throws -> Data {
        let prefix = "data:image/png;base64,"
        guard uri.hasPrefix(prefix), uri.utf8.count <= PetdexPolicy.maximumThumbnailBytes * 4 / 3 + 64,
              let data = Data(base64Encoded: String(uri.dropFirst(prefix.count))),
              data.count <= PetdexPolicy.maximumThumbnailBytes else { throw PetdexError.invalidImage }
        _ = try image(data, allowed: [UTType.png.identifier], maximumDimension: 1_024)
        return data
    }

    /// The top-left frame of a petdex sheet, as PNG.
    static func firstFrame(fromSheet data: Data) throws -> Data {
        guard data.count <= PetdexPolicy.maximumSheetBytes else { throw PetdexError.tooLarge }
        let sheet = try image(data, allowed: [UTType.webP.identifier, UTType.png.identifier],
                              maximumDimension: PetdexPolicy.maximumSheetDimension)
        let crop = CGRect(x: 0, y: 0, width: min(PetdexPolicy.frameWidth, sheet.width),
                          height: min(PetdexPolicy.frameHeight, sheet.height))
        guard let frame = sheet.cropping(to: crop) else { throw PetdexError.invalidImage }
        return try png(frame)
    }

    /// A pet frame scaled up by whole pixels and centered on a square, so it
    /// stays pixel-sharp and nothing is cut off in a round avatar.
    static func avatar(fromFrame data: Data, side: Int = 416) throws -> Data {
        let frame = try image(data, allowed: [UTType.png.identifier], maximumDimension: 1_024)
        let factor = max(1, side / max(frame.width, frame.height))
        let width = frame.width * factor, height = frame.height * factor
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PetdexError.invalidImage
        }
        context.interpolationQuality = .none
        context.draw(frame, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        guard let output = context.makeImage() else { throw PetdexError.invalidImage }
        return try png(output)
    }

    static func image(_ data: Data, allowed: Set<String>, maximumDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, allowed.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PetdexError.invalidImage }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw PetdexError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PetdexError.invalidImage }
        return output as Data
    }
}

/// The public gallery, straight from petdex, for hosts that can't list pets.
/// Sheets are about 2 MB each, so downloads are bounded and a few at a time.
actor PetdexPublicCatalog {
    static let shared = PetdexPublicCatalog()

    private let session: URLSession
    private var manifest: (pets: [PetdexPet], fetchedAt: Date)?
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = PetdexPolicy.requestTimeout
            configuration.timeoutIntervalForResource = PetdexPolicy.requestTimeout * 2
            configuration.httpAdditionalHeaders = ["User-Agent": "bighelp-petdex"]
            self.session = URLSession(configuration: configuration)
        }
    }

    func gallery() async throws -> [PetdexPet] {
        if let manifest, Date().timeIntervalSince(manifest.fetchedAt) < 300 { return manifest.pets }
        let data = try await download(PetdexPolicy.manifestURL, limit: PetdexPolicy.maximumManifestBytes)
        let pets = try PetdexPolicy.pets(fromManifest: data)
        manifest = (pets, Date())
        return pets
    }

    /// Frame 0 from the pet's small preview strip, or from its full sheet when
    /// petdex has no preview for it.
    func thumbnail(_ pet: PetdexPet) async throws -> Data {
        await acquire()
        defer { release() }
        if let preview = PetdexPolicy.previewURL(slug: pet.slug),
           let strip = try? await download(preview, limit: PetdexPolicy.maximumPreviewBytes),
           let frame = try? await Self.firstFrame(strip) {
            return frame
        }
        guard let url = pet.spritesheetURL else { throw PetdexError.unsupported }
        return try await Self.firstFrame(try await download(url, limit: PetdexPolicy.maximumSheetBytes))
    }

    /// A pet's full animation sheet, for its moves.
    func sheet(_ pet: PetdexPet) async throws -> Data {
        guard let url = pet.spritesheetURL else { throw PetdexError.unsupported }
        await acquire()
        defer { release() }
        return try await download(url, limit: PetdexPolicy.maximumSheetBytes)
    }

    private static func firstFrame(_ sheet: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try PetdexSprite.firstFrame(fromSheet: sheet) }.value
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        guard PetdexPolicy.isPetdexURL(url) else { throw PetdexError.blockedAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: PetdexPolicy.requestTimeout)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request, delegate: PetdexRedirectGuard.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              PetdexPolicy.isPetdexURL(http.url) else { throw PetdexError.blockedAddress }
        guard http.expectedContentLength <= Int64(limit) else { throw PetdexError.tooLarge }
        var data = Data()
        data.reserveCapacity(max(0, Int(min(http.expectedContentLength, Int64(limit)))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw PetdexError.tooLarge }
        }
        return data
    }

    private func acquire() async {
        if running < 3 {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// petdex answers its manifest with a redirect to its asset host; a redirect
/// anywhere else is refused before it's followed.
final class PetdexRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = PetdexRedirectGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        PetdexPolicy.isPetdexURL(request.url) ? request : nil
    }
}

/// Where pets come from: the connected Hermes (`pet.gallery` / `pet.thumb`),
/// else petdex itself.
@MainActor
struct PetdexSource {
    let hostGallery: (@MainActor () async throws -> [PetdexPet])?
    let hostThumbnail: (@MainActor (PetdexPet) async throws -> Data)?
    let publicCatalog: PetdexPublicCatalog?
    /// Keeps one host's pets apart from another's in the shared cache.
    let cacheScope: String

    init(store: AgentDirectoryStore?, publicCatalog: PetdexPublicCatalog? = .shared, cacheScope: String = "host") {
        if let store {
            hostGallery = { @MainActor () async throws -> [PetdexPet] in try await store.petGallery() }
            hostThumbnail = { @MainActor (pet: PetdexPet) async throws -> Data in try await store.petThumbnail(pet) }
        } else {
            hostGallery = nil
            hostThumbnail = nil
        }
        self.publicCatalog = publicCatalog
        self.cacheScope = cacheScope
    }

    init(hostGallery: (@MainActor () async throws -> [PetdexPet])?,
         hostThumbnail: (@MainActor (PetdexPet) async throws -> Data)?,
         publicCatalog: PetdexPublicCatalog?, cacheScope: String) {
        self.hostGallery = hostGallery
        self.hostThumbnail = hostThumbnail
        self.publicCatalog = publicCatalog
        self.cacheScope = cacheScope
    }
}

/// A small recently-used cache of pet thumbnails (PNG bytes), shared by every
/// studio sheet, so scrolling back is instant without keeping thousands.
@MainActor
final class PetdexThumbnailCache {
    static let shared = PetdexThumbnailCache()
    static let capacity = 120

    private var values: [String: Data] = [:]
    private var order: [String] = []
    private var loading: [String: Task<Data?, Never>] = [:]

    func cached(_ key: String) -> Data? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// One load per key at a time; failures aren't kept, so a retry can work.
    func value(_ key: String, load: @escaping @MainActor () async -> Data?) async -> Data? {
        if let value = cached(key) { return value }
        if let task = loading[key] { return await task.value }
        let task = Task { @MainActor in await load() }
        loading[key] = task
        let value = await task.value
        loading[key] = nil
        if let value { store(value, for: key) }
        return value
    }

    func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    private func store(_ value: Data, for key: String) {
        values[key] = value
        touch(key)
        while order.count > Self.capacity { values[order.removeFirst()] = nil }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// The studio's Pets tab: the whole gallery, searched live, shown a page at a time.
@MainActor
@Observable
final class PetdexGalleryModel {
    enum Phase: Equatable { case idle, loading, loaded, failed }

    static let pageSize = 24
    static let thumbnailTimeout: Duration = .seconds(15)

    private(set) var phase: Phase = .idle
    private(set) var pets: [PetdexPet] = []
    /// True when the list came from petdex itself rather than the host.
    private(set) var isFromPetdex = false
    private(set) var limit = PetdexGalleryModel.pageSize
    var query = "" {
        didSet { if query != oldValue { limit = Self.pageSize } }
    }

    @ObservationIgnored private let source: PetdexSource
    @ObservationIgnored private let cache: PetdexThumbnailCache

    init(source: PetdexSource, cache: PetdexThumbnailCache = .shared) {
        self.source = source
        self.cache = cache
    }

    var matches: [PetdexPet] { PetdexPolicy.ranked(pets, query: query) }
    var visible: ArraySlice<PetdexPet> { matches.prefix(limit) }

    func loadIfNeeded() async {
        guard phase == .idle || phase == .failed else { return }
        phase = .loading
        if let hostGallery = source.hostGallery, let hostPets = try? await hostGallery(), !hostPets.isEmpty {
            pets = hostPets
            isFromPetdex = false
            phase = .loaded
            return
        }
        if let catalog = source.publicCatalog, let publicPets = try? await catalog.gallery(), !publicPets.isEmpty {
            pets = publicPets
            isFromPetdex = true
            phase = .loaded
            return
        }
        phase = .failed
    }

    /// Grows the page when the last tile shows.
    func reached(_ pet: PetdexPet) {
        let shown = visible
        guard pet.id == shown.last?.id, shown.count < matches.count else { return }
        limit += Self.pageSize
    }

    func cachedThumbnail(_ pet: PetdexPet) -> Data? { cache.cached(key(pet)) }

    func thumbnail(_ pet: PetdexPet) async -> Data? {
        let source = source
        let fromPetdex = isFromPetdex
        return await cache.value(key(pet)) {
            await Self.withTimeout {
                if !fromPetdex, let host = source.hostThumbnail, let data = try? await host(pet) { return data }
                guard let catalog = source.publicCatalog, pet.spritesheetURL != nil else { return nil }
                return try? await catalog.thumbnail(pet)
            }
        }
    }

    /// The picked pet's first frame, ready to be its avatar.
    func avatar(for pet: PetdexPet) async -> Data? {
        guard let frame = await thumbnail(pet) else { return nil }
        return try? await Task.detached(priority: .userInitiated) { try PetdexSprite.avatar(fromFrame: frame) }.value
    }

    private func key(_ pet: PetdexPet) -> String {
        "\(isFromPetdex ? "petdex" : source.cacheScope)|\(pet.slug)"
    }

    private static func withTimeout(_ work: @escaping @MainActor () async -> Data?) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: thumbnailTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
