import Foundation
import Testing
@testable import Bighelp

struct GitHubIntegrationTests {
    @MainActor
    @Test func personalTokenConnectionDoesNotRequireAppRegistrationOrTouchChatAtInitialization() async throws {
        let token = "ghp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "ABCD"
        let transport = PATProbeTransport(expectedToken: token)
        let store = GitHubConnectionStore(ownerID: "fixture-owner", configuration: nil, transport: transport)
        #expect(await transport.requestCount == 0)
        await store.connectPersonalAccessToken(token)
        #expect(await transport.requestCount == 1)
        guard case .confirmAccount(let identity) = store.state else {
            Issue.record("PAT must independently verify identity and await explicit confirmation")
            return
        }
        #expect(identity.login == "fixture-user")
        #expect(store.selectedIdentity == nil)
        store.cancelConnection()
    }

    @MainActor
    @Test func discoveryCachesPartialPagesForOneMinuteAndDeduplicatesColdReads() async throws {
        let cache = GitHubDiscoveryCache()
        let clock = DiscoveryTestClock()
        let gate = DiscoveryTestGate()
        let calls = DiscoveryTestCounter()
        let load: @MainActor @Sendable () async throws -> GitHubResourcePage = {
            calls.value += 1
            await gate.wait()
            return GitHubResourcePage(resources: [], isPartial: true, retryAfter: nil, fetchedAt: clock.now())
        }
        let first = Task { try await cache.page(for: .catalog, clock: clock, load: load) }
        await gate.waitUntilStarted()
        let second = Task { try await cache.page(for: .catalog, clock: clock, load: load) }
        await Task.yield()
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        #expect(calls.value == 1)
        clock.advance(59)
        let cached = try await cache.page(for: .catalog, clock: clock, load: load)
        #expect(cached.isCached && cached.isPartial)
        #expect(calls.value == 1)
        clock.advance(1)
        _ = try await cache.page(for: .catalog, clock: clock, staleWhileRevalidate: false, load: load)
        #expect(calls.value == 2)
    }

    @MainActor
    @Test func staleDiscoveryReturnsImmediatelyAndPublishesOneRefresh() async throws {
        let cache = GitHubDiscoveryCache()
        let clock = DiscoveryTestClock()
        let initial = clock.now()
        _ = try await cache.page(for: .catalog, clock: clock) {
            GitHubResourcePage(resources: [], isPartial: false, retryAfter: nil, fetchedAt: clock.now())
        }
        clock.advance(60)
        let gate = DiscoveryTestGate()
        let calls = DiscoveryTestCounter()
        let load: @MainActor @Sendable () async throws -> GitHubResourcePage = {
            calls.value += 1
            await gate.wait()
            return GitHubResourcePage(resources: [], isPartial: true, retryAfter: nil, fetchedAt: clock.now())
        }
        let stale = try await cache.page(for: .catalog, clock: clock, load: load)
        #expect(stale.isCached && stale.fetchedAt == initial)
        await gate.waitUntilStarted()
        let repeated = try await cache.page(for: .catalog, clock: clock, load: load)
        #expect(repeated.fetchedAt == initial)
        #expect(calls.value == 1)
        await gate.release()
        let refreshed = try await cache.page(for: .catalog, clock: clock, staleWhileRevalidate: false, load: load)
        #expect(refreshed.fetchedAt == clock.now())
        #expect(refreshed.isPartial)
        #expect(cache.lastCheckedAt == clock.now())
        #expect(cache.revision == 2)
    }

    @MainActor
    @Test func invalidationCancelsOldPublicationAndAllowsNewCredentialWork() async throws {
        let cache = GitHubDiscoveryCache()
        let clock = DiscoveryTestClock()
        let gate = DiscoveryTestGate()
        let old = Task {
            try await cache.page(for: .catalog, clock: clock) {
                await gate.wait() // Deliberately ignores cancellation, like a late network callback.
                return GitHubResourcePage(resources: [], isPartial: true, retryAfter: nil, fetchedAt: clock.now())
            }
        }
        await gate.waitUntilStarted()
        cache.invalidate()
        let current = try await cache.page(for: .catalog, clock: clock) {
            GitHubResourcePage(resources: [], isPartial: false, retryAfter: nil, fetchedAt: clock.now())
        }
        let revision = cache.revision
        await gate.release()
        do { _ = try await old.value; Issue.record("Old credential must not publish") } catch {}
        #expect(!current.isPartial)
        #expect(cache.revision == revision)
        let cached = try await cache.page(for: .catalog, clock: clock) { throw GitHubError.invalidResponse }
        #expect(!cached.isPartial && cached.isCached)
    }

    @MainActor
    @Test func cancellingOneWaiterDoesNotCancelSharedDiscovery() async throws {
        let cache = GitHubDiscoveryCache()
        let clock = DiscoveryTestClock()
        let gate = DiscoveryTestGate()
        let load: @MainActor @Sendable () async throws -> GitHubResourcePage = {
            await gate.wait()
            return GitHubResourcePage(resources: [], isPartial: false, retryAfter: nil, fetchedAt: clock.now())
        }
        let cancelled = Task { try await cache.page(for: .catalog, clock: clock, load: load) }
        await gate.waitUntilStarted()
        let survivor = Task { try await cache.page(for: .catalog, clock: clock, load: load) }
        cancelled.cancel()
        await gate.release()
        do { _ = try await cancelled.value; Issue.record("Cancelled caller received data") } catch {}
        _ = try await survivor.value
        #expect(cache.lastCheckedAt == clock.now())
    }

    @MainActor
    @Test func discoveryFailureCooldownHonorsServerRetryDeadline() async throws {
        let cache = GitHubDiscoveryCache()
        let clock = DiscoveryTestClock()
        let calls = DiscoveryTestCounter()
        let until = clock.now().addingTimeInterval(120)
        let load: @MainActor @Sendable () async throws -> GitHubResourcePage = {
            calls.value += 1
            throw GitHubError.throttled(until: until)
        }
        for advance in [0.0, 59, 1, 59] {
            clock.advance(advance)
            do { _ = try await cache.page(for: .catalog, clock: clock, load: load); Issue.record("Expected throttle") }
            catch { #expect(error as? GitHubError == .throttled(until: until)) }
        }
        #expect(calls.value == 1)
        clock.advance(1)
        _ = try? await cache.page(for: .catalog, clock: clock, load: load)
        #expect(calls.value == 2)
    }

    @MainActor
    @Test func derivedCatalogQueriesKeepSnapshotAgeButBoundFailedRefreshAttempts() async throws {
        let cache = GitHubDiscoveryCache()
        let clock = DiscoveryTestClock()
        let snapshotDate = clock.now()
        _ = try await cache.page(for: .catalog, clock: clock) {
            GitHubResourcePage(resources: [], isPartial: false, retryAfter: nil, fetchedAt: snapshotDate)
        }
        clock.advance(60)
        let network = DiscoveryTestCounter()
        let derived = DiscoveryTestCounter()
        let fail: @MainActor @Sendable () async throws -> GitHubResourcePage = {
            network.value += 1
            throw GitHubError.networkUnavailable
        }
        _ = try? await cache.page(for: .catalog, clock: clock, staleWhileRevalidate: false, load: fail)
        let lastNetworkCheck = clock.now()
        let load: @MainActor @Sendable () async throws -> GitHubResourcePage = {
            derived.value += 1
            return try await cache.page(for: .catalog, clock: clock, staleWhileRevalidate: false, load: fail)
        }
        let key = GitHubDiscoveryCache.Key.search(.repository, "app", nil)
        let first = try await cache.page(for: key, clock: clock, staleWhileRevalidate: false, load: load)
        #expect(first.isCached && first.isPartial && first.fetchedAt == snapshotDate)
        let revision = cache.revision
        for _ in 0..<59 {
            clock.advance(1)
            let page = try await cache.page(for: key, clock: clock, staleWhileRevalidate: false, load: load)
            #expect(page.fetchedAt == snapshotDate)
            #expect(cache.revision == revision, "Reading a derived snapshot must not republish it")
        }
        #expect(derived.value == 1 && network.value == 1)
        #expect(cache.lastCheckedAt == lastNetworkCheck)
        // Reads above cannot slide either deadline forward indefinitely.
        clock.advance(1)
        _ = try? await cache.page(for: key, clock: clock, staleWhileRevalidate: false, load: load)
        #expect(derived.value == 2 && network.value == 2)
        let failedRevision = cache.revision
        for _ in 0..<10 {
            _ = try await cache.page(for: key, clock: clock, staleWhileRevalidate: false, load: load)
        }
        #expect(cache.revision == failedRevision)
        #expect(derived.value == 2 && network.value == 2)
    }

    @Test func rateLimitHonorsHTTPDateAndResetWithoutBlockingOtherPrimaryBuckets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let url = URL(string: "https://api.github.com/search/issues")!
        var budget = GitHubRateLimitBudget()
        let exhausted = GitHubHTTPResponse(data: Data(), statusCode: 200, url: url,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1100", "X-RateLimit-Resource": "search"])
        #expect(budget.record(exhausted, search: true, now: now) == nil)
        #expect(budget.blockedUntil(search: true) == Date(timeIntervalSince1970: 1100))
        #expect(budget.blockedUntil(search: false) <= now)
        let retry = GitHubHTTPResponse(data: Data(), statusCode: 429, url: url,
            headers: ["Retry-After": "Thu, 01 Jan 1970 00:20:00 GMT"])
        #expect(budget.record(retry, search: true, now: now) == Date(timeIntervalSince1970: 1200))
        #expect(budget.blockedUntil(search: false) == Date(timeIntervalSince1970: 1200))
    }

    @Test func secondaryLimitFallbackEscalatesButOrdinaryForbiddenDoesNotThrottle() {
        let now = Date(timeIntervalSince1970: 1_000)
        let url = URL(string: "https://api.github.com/user/repos")!
        var budget = GitHubRateLimitBudget()
        let forbidden = GitHubHTTPResponse(data: Data(#"{"message":"Resource not accessible by integration"}"#.utf8),
            statusCode: 403, url: url, headers: [:])
        #expect(budget.record(forbidden, search: false, now: now) == nil)
        let limited = GitHubHTTPResponse(data: Data(#"{"message":"You have exceeded a secondary rate limit"}"#.utf8),
            statusCode: 403, url: url, headers: [:])
        #expect(budget.record(limited, search: false, now: now) == now.addingTimeInterval(60))
        #expect(budget.record(limited, search: false, now: now.addingTimeInterval(60)) == now.addingTimeInterval(180))
        let longRetry = GitHubHTTPResponse(data: Data(), statusCode: 429, url: url, headers: ["Retry-After": "172800"])
        #expect(budget.record(longRetry, search: false, now: now) == now.addingTimeInterval(172800))
    }

    @Test func deviceAuthorizationRequiresTheRealVerificationOriginAndStrictExpiry() throws {
        let valid = Data(#"{"device_code":"fixture-device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8)
        let code = try GitHubDeviceCode.decode(data: valid)
        #expect(code.userCode == "ABCD-EFGH")
        #expect(code.verificationURI.absoluteString == "https://github.com/login/device")
        #expect(code.expiresIn == 900)
        #expect(code.interval == 5)
        let wrongOrigin = Data(#"{"device_code":"fixture-device-code","user_code":"ABCD-EFGH","verification_uri":"https://example.invalid/login/device","expires_in":900,"interval":5}"#.utf8)
        #expect(throws: (any Error).self) { try GitHubDeviceCode.decode(data: wrongOrigin) }
        let booleanExpiry = Data(#"{"device_code":"fixture-device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":true,"interval":5}"#.utf8)
        #expect(throws: (any Error).self) { try GitHubDeviceCode.decode(data: booleanExpiry) }
    }
}

@MainActor
private final class DiscoveryTestCounter { var value = 0 }

private final class DiscoveryTestClock: GitHubClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        advance(seconds)
    }
}

private actor DiscoveryTestGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        started = true
        await withCheckedContinuation {
            waiters.append($0)
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor PATProbeTransport: GitHubTransport {
    enum ProbeError: Error { case unexpectedRequest }
    private let expectedToken: String
    private(set) var requestCount = 0

    init(expectedToken: String) { self.expectedToken = expectedToken }

    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        requestCount += 1
        guard request.url?.absoluteString == "https://api.github.com/user",
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedToken else {
            throw ProbeError.unexpectedRequest
        }
        return GitHubHTTPResponse(data: Data(#"{"id":42,"login":"fixture-user","type":"User"}"#.utf8), statusCode: 200, url: request.url!, headers: [:])
    }
}
