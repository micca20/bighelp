import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct DashboardModelTests {
    @Test func initialLoadWaitsForVerifiedConnectionAndThenLoadsWithoutRetry() async {
        var generation: UInt64?
        let source = ChangingDashboardSource()
        let model = DashboardModel(source: source, verifiedConnectionGeneration: { generation })

        await model.load()
        await model.refreshAfterExternalChange()
        #expect(source.loadCount == 0)
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)

        generation = 1
        await model.load()
        #expect(source.loadCount == 1)
        #expect(model.state == .loaded)
        #expect(model.snapshot?.inbox.first?.title == "Update 1")
    }

    @Test func dashboardResponseFromReplacedConnectionCannotPublish() async {
        var generation: UInt64? = 1
        let source = InterleavedDashboardSource()
        let model = DashboardModel(source: source, verifiedConnectionGeneration: { generation })
        let loading = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 1)
        generation = 2
        source.resumeLoad(at: 0, title: "Old host")
        await loading.value
        #expect(model.snapshot == nil)
        #expect(model.state == .idle)
        let replacement = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 2)
        source.resumeLoad(at: 1, title: "Current host")
        await replacement.value
        #expect(model.snapshot?.inbox.first?.title == "Current host")
    }

    @Test func disappearingHomeDoesNotPublishCancellationAsDashboardFailure() async {
        let source = InterleavedDashboardSource()
        let model = DashboardModel(source: source)
        let loading = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 1)
        loading.cancel()
        source.failLoad(at: 0, error: CancellationError())
        await loading.value
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)
    }

    @Test func inboxPrimaryActionOpensAssociatedSession() {
        #expect(DashboardInboxInteractionPolicy.primaryAction == .openSession)
        #expect(DashboardInboxInteractionPolicy.secondaryAction == .startChat)
    }

    @Test func tappingAnActivityUpdateDoesNotPresentAStandalonePopup() {
        #expect(DashboardInboxInteractionPolicy.primaryAction == .openSession)
    }

    @Test func unavailableDeviceWeatherDoesNotUseAnInboxForecastForAnotherLocation() async throws {
        let reference = Date(timeIntervalSince1970: 1_788_000_300)
        let card = try weatherCard(cardID: String(repeating: "7", count: 32), sourceTimestamp: reference,
                                   location: "A different city", temperature: 70)
        let model = DashboardModel(source: FlakyWeatherDashboardSource(card: card),
                                   weather: WeatherLoaderFixture(result: .success(nil)), now: { reference })
        await model.load()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.snapshot?.weather == nil,
                "A production location-weather panel must never substitute an agent card's city")
        #expect(model.snapshot?.inbox.count == 1)
    }

    @Test func weatherRefreshWorksWithoutAHostSnapshot() async throws {
        let expected = DashboardWeather(city: "Device city", condition: "Clear", temperature: 61,
                                        high: 65, low: 52, systemImage: "sun.max.fill")
        let model = DashboardModel(source: DashboardFixtureSource(shouldFail: true),
                                   weather: WeatherLoaderFixture(result: .success(expected)))
        await model.refreshWeather()
        #expect(model.currentLocationWeather == expected)
        #expect(model.snapshot == nil)
    }

    @Test func simultaneousWeatherRefreshesShareOneRequest() async {
        let loader = CountingDeferredWeatherLoader()
        let model = DashboardModel(source: DashboardFixtureSource(), weather: loader)
        let first = Task { await model.refreshWeather() }
        let second = Task { await model.refreshWeather() }
        for _ in 0..<100 where loader.loadCount == 0 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(loader.loadCount == 1)
        loader.finishAll()
        await first.value
        await second.value
    }

    @Test func resetRejectsStandaloneWeatherCompletion() async {
        let loader = CountingDeferredWeatherLoader()
        let model = DashboardModel(source: DashboardFixtureSource(), weather: loader)
        let loading = Task { await model.refreshWeather() }
        for _ in 0..<100 where loader.loadCount == 0 { await Task.yield() }
        #expect(loader.loadCount == 1)
        model.resetForAccountBoundary()
        loader.finishAll()
        await loading.value
        #expect(model.currentLocationWeather == nil)
        #expect(model.snapshot == nil)
    }

    @Test func newerSameAccountDashboardLoadOwnsSnapshotAndWeather() async {
        let source = InterleavedDashboardSource()
        let weather = WeatherLoaderSpy(result: DashboardWeather(
            city: "Current City",
            condition: "Clear",
            temperature: 72,
            high: 75,
            low: 60,
            systemImage: "sun.max.fill"
        ))
        let model = DashboardModel(source: source, weather: weather)

        let olderLoad = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 1)
        let newerLoad = Task { await model.refresh() }
        await source.waitUntilLoadStarts(count: 2)

        source.resumeLoad(at: 1, title: "Newest update")
        await newerLoad.value
        source.resumeLoad(at: 0, title: "Stale update")
        await olderLoad.value

        #expect(model.snapshot?.inbox.map(\.title) == ["Newest update"])
        #expect(weather.loadCount == 1)
    }

    @Test func supersededCleanupCannotRemoveAReplacementSignalFromTheNewerLoad() async {
        let source = InterleavedCleanupDashboardSource()
        let model = DashboardModel(source: source)

        let olderLoad = Task { await model.load() }
        await source.waitUntilCleanupStarts()
        let newerLoad = Task { await model.refresh() }
        await source.waitUntilLoadStarts(count: 2)
        await newerLoad.value

        source.finishCleanup()
        await olderLoad.value

        #expect(model.snapshot?.inbox.map(\.title) == ["Replacement update"])
    }

    @Test func homeContentGrowsWhenAChannelContainsMoreThanFiveSignals() async throws {
        let five = try await dashboardContentHeight(signalCount: 5)
        let six = try await dashboardContentHeight(signalCount: 6)

        #expect(six > five + 80)
    }

    @Test func liveWeatherStartsBeforeStaleSignalCleanupFinishes() async throws {
        let source = SuspendedCleanupDashboardSource()
        let weather = WeatherLoaderSpy(result: DashboardWeather(
            city: "Kansas City, MO",
            condition: "Mostly Clear",
            temperature: 80,
            high: 100,
            low: 79,
            systemImage: "sun.max.fill",
            sourceName: "Apple Weather"
        ))
        let model = DashboardModel(source: source, weather: weather)

        let loading = Task { await model.load() }
        await source.waitUntilCleanupStarts()
        for _ in 0..<100 where weather.loadCount == 0 {
            await Task.yield()
        }

        #expect(weather.loadCount == 1)
        #expect(model.snapshot?.weather?.city == "Kansas City, MO")

        source.finishCleanup()
        await loading.value
    }

    @Test func liveLocationWeatherEnrichesHomeWithoutReplacingHermesDashboardContent() async throws {
        let base = WeatherEnrichmentBaseSource()
        let weather = DashboardWeather(
            city: "Kansas City, MO",
            condition: "Mostly Clear",
            temperature: 80,
            high: 100,
            low: 79,
            systemImage: "sun.max.fill",
            sourceName: "Apple Weather",
            sourceTimestamp: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let model = DashboardModel(
            source: base,
            weather: WeatherLoaderFixture(result: .success(weather))
        )

        await model.load()
        while model.snapshot?.weather != weather { await Task.yield() }
        let snapshot = try #require(model.snapshot)

        #expect(snapshot.weather == weather)
        #expect(snapshot.inbox.map(\.id) == ["hermes-update"])
        #expect(snapshot.attentionItems.map(\.id) == ["hermes-decision"])
        #expect(snapshot.completedItems.map(\.id) == ["hermes-completion"])
    }

    @Test func weatherFailureNeverHidesHermesDashboardAndMutationsStillReachHermes() async throws {
        let base = WeatherEnrichmentBaseSource()
        let model = DashboardModel(
            source: base,
            weather: WeatherLoaderFixture(result: .failure(WeatherLoaderFixture.Error.unavailable))
        )

        await model.load()
        let snapshot = try #require(model.snapshot)
        await model.setUpdateRead(id: "hermes-update", isRead: true)
        await model.setUpdatePinned(id: "hermes-update", isPinned: true)
        await model.dismissUpdate(id: "hermes-update")

        #expect(snapshot.weather == nil)
        #expect(snapshot.inbox.map(\.id) == ["hermes-update"])
        let mutation = try #require(base.stateMutation)
        #expect(mutation.0 == "hermes-update")
        #expect(mutation.1)
        #expect(mutation.2)
        #expect(base.dismissedID == "hermes-update")
    }

    @Test func hermesRefreshFailureKeepsAlreadyLoadedLiveLocationWeather() async throws {
        let source = FlakyDashboardSource()
        let weather = DashboardWeather(
            city: "Kansas City, MO",
            condition: "Mostly Clear",
            temperature: 80,
            high: 100,
            low: 79,
            systemImage: "sun.max.fill",
            sourceName: "Apple Weather"
        )
        let model = DashboardModel(
            source: source,
            weather: WeatherLoaderFixture(result: .success(weather))
        )

        await model.load()
        while model.snapshot?.weather != weather { await Task.yield() }
        source.shouldFail = true
        await model.refresh()

        #expect(model.snapshot?.weather == weather)
        #expect(model.lastUpdatedLabel == "Could not refresh")
    }

    @Test func slowLiveWeatherNeverDelaysHermesDashboardAndEnrichesItWhenReady() async {
        let base = WeatherEnrichmentBaseSource()
        let weather = DeferredWeatherLoader()
        let model = DashboardModel(source: base, weather: weather)
        let loading = Task { await model.load() }

        await weather.waitUntilLoadStarts()
        await loading.value

        #expect(model.state == .loaded)
        #expect(model.snapshot?.inbox.map(\.id) == ["hermes-update"])

        let liveWeather = DashboardWeather(
            city: "Kansas City, MO",
            condition: "Mostly Clear",
            temperature: 80,
            high: 100,
            low: 79,
            systemImage: "sun.max.fill",
            sourceName: "Apple Weather",
            sourceTimestamp: Date(timeIntervalSince1970: 1_788_000_000)
        )
        weather.resume(returning: liveWeather)
        while model.snapshot?.weather != liveWeather { await Task.yield() }

        #expect(model.snapshot?.inbox.map(\.id) == ["hermes-update"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["hermes-decision"])
        #expect(model.snapshot?.completedItems.map(\.id) == ["hermes-completion"])
    }

    @Test func accountResetRejectsLiveWeatherFromThePreviousGeneration() async {
        let weather = DeferredWeatherLoader()
        let model = DashboardModel(source: WeatherEnrichmentBaseSource(), weather: weather)

        await model.load()
        await weather.waitUntilLoadStarts()
        model.resetForAccountBoundary()
        weather.resume(returning: DashboardWeather(
            city: "Old account city",
            condition: "Clear",
            temperature: 70,
            high: 75,
            low: 60,
            systemImage: "sun.max.fill"
        ))
        await weather.waitUntilLoadFinishes()
        await Task.yield()

        #expect(model.state == .idle)
        #expect(model.snapshot == nil)
    }

    @Test func cancelledLocationWaiterDoesNotStrandTheNextWeatherRequest() async throws {
        let requests = DashboardWeatherLocationRequestPool<Int>()
        var requestCount = 0
        let first = Task {
            try await requests.value {
                requestCount += 1
            }
        }
        while requests.pendingCount == 0 { await Task.yield() }

        first.cancel()
        do {
            _ = try await first.value
            Issue.record("A cancelled location waiter unexpectedly completed.")
        } catch is CancellationError {
            // Expected: cancellation must remove and resume this waiter.
        }
        #expect(requests.pendingCount == 0)

        let second = Task {
            try await requests.value {
                requestCount += 1
            }
        }
        while requests.pendingCount == 0 { await Task.yield() }
        #expect(requestCount == 2)

        requests.finish(returning: 42)
        #expect(try await second.value == 42)
        #expect(requests.pendingCount == 0)
    }

    @Test func resetInvalidatesAnInFlightRemoteLoad() async {
        let source = DeferredDashboardSource()
        let model = DashboardModel(source: source)
        let loading = Task { await model.load() }

        await source.waitUntilLoadStarts()
        model.resetForAccountBoundary()
        source.resumeLoad(with: DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "old-account-update",
                title: "Old account",
                detail: "Should not be restored",
                agentName: "Juno",
                status: "Old"
            )],
            attentionItems: [],
            completedItems: [],
            agents: []
        ))
        await loading.value

        #expect(model.snapshot == nil)
        #expect(model.state == .idle)
        #expect(model.lastUpdatedLabel == "Not updated yet")
    }

    @Test func refreshPreservesItemIdentityAndUpdatesFreshness() async {
        let source = DashboardFixtureSource()
        let model = DashboardModel(source: source)

        await model.load()
        let ids = model.snapshot!.inbox.map(\.id)

        await model.refresh()

        #expect(model.snapshot!.inbox.map(\.id) == ids)
        #expect(model.lastUpdatedLabel == "Updated just now")
    }

    @Test func refreshFetchesCurrentHermesDataInsteadOfOnlyChangingTheLabel() async {
        let source = ChangingDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()
        await model.refresh()

        #expect(source.loadCount == 2)
        #expect(model.snapshot?.inbox.first?.title == "Update 2")
    }

    @Test func refreshFailureKeepsTheLastSuccessfulDashboardVisible() async {
        let source = FlakyDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()
        let snapshot = model.snapshot

        source.shouldFail = true
        await model.refresh()

        #expect(model.state == .loaded)
        #expect(model.snapshot == snapshot)
        #expect(model.lastUpdatedLabel == "Could not refresh")
    }

    @Test func newestValidatedPersistedWeatherCardProjectsIntoTheHomeWeatherSlot() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = try weatherCard(
            cardID: String(repeating: "1", count: 32),
            sourceTimestamp: now.addingTimeInterval(-1_800),
            location: "Older City",
            temperature: 68
        )
        let newest = try weatherCard(
            cardID: String(repeating: "2", count: 32),
            sourceTimestamp: now.addingTimeInterval(-300),
            location: "Kansas City, MO",
            temperature: 79
        )

        let projected = try #require(DashboardWeatherProjection.project(
            from: [
                DashboardInboxItem(
                    id: "newer-event",
                    title: "Forecast",
                    detail: "Current forecast",
                    agentName: "Juno",
                    status: "Now",
                    card: newest
                ),
                DashboardInboxItem(
                    id: "older-event",
                    title: "Forecast",
                    detail: "Older forecast",
                    agentName: "Juno",
                    status: "Earlier",
                    card: older
                ),
            ],
            now: now
        ))

        #expect(projected.cardID == String(repeating: "2", count: 32))
        #expect(projected.city == "Kansas City, MO")
        #expect(projected.condition == "Clear")
        #expect(projected.temperature == 79)
        #expect(projected.high == 84)
        #expect(projected.low == 66)
        #expect(projected.systemImage == "sun.max.fill")
        #expect(projected.sourceName == "Fixture Weather Service")
        #expect(projected.freshness == .fresh)
    }

    @Test func weatherProjectionUsesSourceTimeAndValidityInsteadOfUntrustedAgeCopy() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = try weatherCard(
            cardID: String(repeating: "3", count: 32),
            sourceTimestamp: now.addingTimeInterval(-3 * 60 * 60),
            location: "Stale City",
            temperature: 70,
            ageSeconds: 1
        )
        let expiredByAge = try weatherCard(
            cardID: String(repeating: "4", count: 32),
            sourceTimestamp: now.addingTimeInterval(-7 * 60 * 60),
            location: "Expired City",
            temperature: 70
        )
        let expiredByValidity = try weatherCard(
            cardID: String(repeating: "5", count: 32),
            sourceTimestamp: now.addingTimeInterval(-600),
            location: "Expired Validity",
            temperature: 70,
            validUntil: now.addingTimeInterval(-1)
        )

        #expect(DashboardWeatherProjection.project(
            from: [weatherItem(id: "stale", card: stale)],
            now: now
        )?.freshness == .stale)
        #expect(DashboardWeatherProjection.project(
            from: [weatherItem(id: "old", card: expiredByAge)],
            now: now
        ) == nil)
        #expect(DashboardWeatherProjection.project(
            from: [weatherItem(id: "expired", card: expiredByValidity)],
            now: now
        ) == nil)
    }

    @Test func refreshFailureKeepsProjectedPersistedWeatherVisible() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = FlakyWeatherDashboardSource(card: try weatherCard(
            cardID: String(repeating: "6", count: 32),
            sourceTimestamp: now.addingTimeInterval(-60),
            location: "Kansas City, MO",
            temperature: 79
        ))
        let model = DashboardModel(source: source, now: { now })

        await model.load()
        let projected = model.snapshot?.weather
        source.shouldFail = true
        await model.refresh()

        #expect(projected?.city == "Kansas City, MO")
        #expect(model.snapshot?.weather == projected)
        #expect(model.lastUpdatedLabel == "Could not refresh")
    }

    @Test func refreshFailureDoesNotKeepAProjectedWeatherCardPastItsMaximumAge() async throws {
        let sourceTime = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = sourceTime.addingTimeInterval(60)
        let source = FlakyWeatherDashboardSource(card: try weatherCard(
            cardID: String(repeating: "7", count: 32),
            sourceTimestamp: sourceTime,
            location: "Kansas City, MO",
            temperature: 79
        ))
        let model = DashboardModel(source: source, now: { clock })

        await model.load()
        #expect(model.snapshot?.weather != nil)
        source.shouldFail = true
        clock = sourceTime.addingTimeInterval(7 * 60 * 60)
        await model.refresh()

        #expect(model.snapshot?.weather == nil)
        #expect(model.snapshot?.inbox.map(\.id) == ["weather"])
    }

    @Test func individualDismissalRemovesOnlyTheChosenRowAfterHermesAcceptsIt() async {
        let source = ManagingDashboardSource()
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.dismissUpdate(id: "update-1")
        await model.dismissAttention(id: "attention-1")

        #expect(source.dismissedIDs == ["update-1", "attention-1"])
        #expect(model.snapshot?.inbox.map(\.id) == ["update-2"])
        #expect(model.snapshot?.attentionItems.isEmpty == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func approvalResponseUsesLoadedRequestWithoutReplacingValidatedSummaryScope() async {
        let source = DashboardApprovalResponseSource()
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.load()

        await model.respondToApproval(itemID: source.itemID, decision: .always)

        #expect(source.loadedIDs.isEmpty)
        #expect(source.submissions.isEmpty)
        #expect(model.mutationErrorMessage == "Hermes did not offer that approval scope.")

        await model.respondToApproval(itemID: source.itemID, decision: .session)

        #expect(source.loadedIDs == [source.loaded.request.id])
        #expect(source.submissions == [DashboardApprovalResponseSource.Submission(
            request: source.loaded.request,
            decision: .session
        )])
        #expect(model.snapshot?.attentionItems.isEmpty == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func clearAllUsesTheNewestVisibleTimestampSoNewerEventsSurvive() async {
        let source = ManagingDashboardSource()
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.clearUpdates()
        await model.clearAttention()

        #expect(source.bulkDismissals.count == 2)
        #expect(source.bulkDismissals[0].types == ["channel.message"])
        #expect(source.bulkDismissals[0].createdBefore == Date(timeIntervalSince1970: 20))
        #expect(source.bulkDismissals[1].types == ["approval.required", "attention.required"])
        #expect(source.bulkDismissals[1].createdBefore == Date(timeIntervalSince1970: 30))
        #expect(model.snapshot?.inbox.isEmpty == true)
        #expect(model.snapshot?.attentionItems.isEmpty == true)
    }

    @Test func failedDismissalKeepsTheRowAndSurfacesARetryableMessage() async {
        let source = ManagingDashboardSource()
        source.shouldFailMutations = true
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.dismissUpdate(id: "update-1")

        #expect(model.snapshot?.inbox.map(\.id) == ["update-1", "update-2"])
        #expect(model.mutationErrorMessage == "That item could not be removed. Please try again.")
    }

    @Test func lostDismissalReceiptReconcilesAnItemAlreadyRemovedByHermes() async {
        let source = ManagingDashboardSource()
        source.shouldFailMutations = true
        source.removeFailedDismissalFromNextLoad = true
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.dismissUpdate(id: "update-1")

        #expect(source.loadCount == 2)
        #expect(model.snapshot?.inbox.map(\.id) == ["update-2"])
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func completedDismissalCannotBeUndoneByAnOlderRefresh() async {
        let source = StaleDismissalDashboardSource()
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        let refresh = Task { await model.refresh() }
        await source.waitUntilStaleRefreshStarts()
        await model.dismissUpdate(id: "update-1")

        #expect(model.snapshot?.inbox.map(\.id) == ["update-2"])
        source.finishStaleRefresh()
        await refresh.value

        #expect(model.snapshot?.inbox.map(\.id) == ["update-2"])
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func readAndPinMutationsPersistThenProjectPinnedRowsFirst() async {
        let source = ManagingDashboardSource()
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.setUpdateRead(id: "update-2", isRead: true)
        await model.setUpdatePinned(id: "update-2", isPinned: true)

        #expect(source.stateMutations == [
            .init(id: "update-2", isRead: true, isPinned: false),
            .init(id: "update-2", isRead: true, isPinned: true),
        ])
        #expect(model.snapshot?.inbox.map(\.id) == ["update-2", "update-1"])
        #expect(model.snapshot?.inbox.first?.isRead == true)
        #expect(model.snapshot?.inbox.first?.isPinned == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func attentionReadAndPinMutationsUseTheOfficialEventStateOperation() async {
        let source = ManagingDashboardSource()
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.setAttentionRead(id: "attention-1", isRead: true)
        await model.setAttentionPinned(id: "attention-1", isPinned: true)

        #expect(source.stateMutations.suffix(2) == [
            .init(id: "attention-1", isRead: true, isPinned: false),
            .init(id: "attention-1", isRead: true, isPinned: true),
        ])
        #expect(model.snapshot?.attentionItems.first?.isRead == true)
        #expect(model.snapshot?.attentionItems.first?.isPinned == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func failedReadOrPinMutationKeepsTheCanonicalRowState() async {
        let source = ManagingDashboardSource()
        source.shouldFailMutations = true
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 100) })
        await model.load()

        await model.setUpdatePinned(id: "update-1", isPinned: true)

        #expect(model.snapshot?.inbox.first(where: { $0.id == "update-1" })?.isPinned == false)
        #expect(model.mutationErrorMessage == "That item could not be updated. Please try again.")
    }

    @Test func notificationFocusIsConsumedOnlyByTheMatchingLoadedInboxRow() async {
        let model = DashboardModel(
            source: ManagingDashboardSource(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        model.focusUpdate(id: "update-2")
        #expect(model.focusedUpdateID == nil)

        await model.load()
        model.focusUpdate(id: "update-2")
        #expect(model.focusedUpdateID == "update-2")

        model.consumeFocusedUpdate(id: "update-1")
        #expect(model.focusedUpdateID == "update-2")
        model.consumeFocusedUpdate(id: "update-2")
        #expect(model.focusedUpdateID == nil)

        model.requestUpdateFocus(id: "attention-1")
        #expect(model.focusedAttentionID == "attention-1")
        model.consumeFocusedAttention(id: "update-2")
        #expect(model.focusedAttentionID == "attention-1")
        model.consumeFocusedAttention(id: "attention-1")
        #expect(model.focusedAttentionID == nil)
    }

    @Test func loadAutomaticallyRemovesExpiredUpdatesAndDecisionRequests() async {
        let source = RetentionDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()

        #expect(source.dismissedIDs == ["expired-update", "expired-decision"])
        #expect(model.snapshot?.inbox.map(\.id) == ["fresh-update"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["fresh-decision"])
    }

    @Test func loadAutomaticallyRemovesRowsForClosedSessionsEvenWhenTheyAreRecent() async {
        let source = ClosedSessionDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()

        #expect(source.dismissedIDs == ["closed-update", "closed-decision"])
        #expect(model.snapshot?.inbox.map(\.id) == ["open-update"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["open-decision"])
    }

    @Test func terminalTurnNotificationDoesNotDismissUnprovenOrNewerSessionRows() async {
        let source = TerminalSessionDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()
        await model.handleTerminalSessionEvent(
            sessionID: "terminal-session",
            eventType: "session.completed"
        )

        #expect(source.dismissedIDs.isEmpty)
        #expect(model.snapshot?.inbox.map(\.id) == ["terminal-update"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["terminal-decision"])
    }

    @Test func clarificationAttentionKeepsHermesQuestionChoicesCustomReplyAndDeadline() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_000)
        let request = DashboardClarificationRequest(
            eventID: "clarify-event",
            requestID: "clarify-real-id",
            sessionID: "session-clarify",
            question: "Which release channel should I use?",
            choices: ["TestFlight", "App Store"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: expiresAt
        )
        let item = DashboardAttentionItem(
            id: request.eventID,
            title: "Hermes needs guidance",
            detail: request.question,
            urgency: .important,
            sessionID: request.sessionID,
            interaction: .clarification(request)
        )

        guard case .clarification(let projected) = item.interaction else {
            Issue.record("Clarify was flattened into a generic attention item")
            return
        }
        #expect(projected.requestID == "clarify-real-id")
        #expect(projected.question == "Which release channel should I use?")
        #expect(projected.choices == ["TestFlight", "App Store"])
        #expect(projected.allowsCustomResponse)
        #expect(projected.expiresAt == expiresAt)
        #expect(projected.isExpired(at: expiresAt.addingTimeInterval(-1)) == false)
        #expect(projected.isExpired(at: expiresAt))
    }

    @Test func clarificationCanBeResolvedFromHomeAndOnlyThenLeavesNeedsYou() async {
        let source = ClarificationDashboardSource(expiresAt: Date(timeIntervalSince1970: 2_000))
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await model.load()

        await model.respondToClarification(
            itemID: "clarify-event",
            response: "Use TestFlight"
        )

        #expect(source.responses == ["Use TestFlight"])
        #expect(model.snapshot?.attentionItems.isEmpty == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func expiredClarificationLeavesNeedsYouWithoutSubmittingAResponse() async {
        let source = ClarificationDashboardSource(expiresAt: Date(timeIntervalSince1970: 999))
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await model.load()

        #expect(source.responses.isEmpty)
        #expect(model.snapshot?.attentionItems.isEmpty == true)
    }

    @Test func terminalSessionCleanupDoesNotEraseStructuredDecisionCards() async {
        let source = ClarificationDashboardSource(expiresAt: Date(timeIntervalSince1970: 2_000))
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await model.load()

        await model.handleTerminalSessionEvent(
            sessionID: "session-clarify",
            eventType: "session.completed"
        )

        #expect(source.dismissedIDs.isEmpty)
        #expect(model.snapshot?.attentionItems.map(\.id) == ["clarify-event"])
    }
}

@MainActor
private final class ClarificationDashboardSource: DashboardDataSource, DashboardClarificationClient {
    let expiresAt: Date
    private(set) var responses: [String] = []
    private(set) var dismissedIDs: [String] = []

    init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        let request = DashboardClarificationRequest(
            eventID: "clarify-event",
            requestID: "clarify-real-id",
            sessionID: "session-clarify",
            question: "Which release channel should I use?",
            choices: ["TestFlight", "App Store"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: expiresAt
        )
        return DashboardSnapshot(
            weather: nil,
            inbox: [],
            attentionItems: [DashboardAttentionItem(
                id: request.eventID,
                title: "Hermes needs guidance",
                detail: request.question,
                urgency: .important,
                sessionID: request.sessionID,
                interaction: .clarification(request),
                createdAt: Date(timeIntervalSince1970: 900)
            )],
            completedItems: [],
            agents: []
        )
    }

    func respond(
        to request: DashboardClarificationRequest,
        response: String
    ) async throws -> DashboardClarificationReceipt {
        responses.append(response)
        return DashboardClarificationReceipt(
            eventID: request.eventID,
            requestID: request.requestID
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private func weatherItem(id: String, card: GenerativeUICard) -> DashboardInboxItem {
    DashboardInboxItem(
        id: id,
        title: "Forecast",
        detail: "Weather update",
        agentName: "Juno",
        status: "Now",
        card: card
    )
}

private func weatherCard(
    cardID: String,
    sourceTimestamp: Date,
    location: String,
    temperature: Double,
    ageSeconds: Int = 300,
    validUntil: Date? = nil
) throws -> GenerativeUICard {
    let formatter = ISO8601DateFormatter()
    var provenance: [String: Any] = [
        "source_name": "Fixture Weather Service",
        "source_timestamp": formatter.string(from: sourceTimestamp),
        "retrieved_at": formatter.string(from: sourceTimestamp.addingTimeInterval(60)),
        "cache_status": "live",
        "age_seconds": ageSeconds,
    ]
    if let validUntil {
        provenance["valid_until"] = formatter.string(from: validUntil)
    }
    return try GenerativeUICard.decode([
        "schema": "loopdy.generative_ui",
        "version": 2,
        "component": "weather_forecast",
        "title": "Forecast",
        "data": [
            "location": location,
            "timezone": "America/Chicago",
            "units": "us",
            "current": [
                "condition_code": "clear",
                "condition_label": "Clear",
                "temperature": temperature,
            ],
            "periods": [[
                "id": "today",
                "label": "Today",
                "start_at": formatter.string(from: sourceTimestamp),
                "end_at": formatter.string(from: sourceTimestamp.addingTimeInterval(3_600)),
                "condition_code": "clear",
                "condition_label": "Clear",
                "high": 84,
                "low": 66,
                "precipitation_percent": 5,
            ]],
        ],
        "provenance": provenance,
        "content_hash": String(repeating: "a", count: 64),
        "created_at": formatter.string(from: sourceTimestamp.addingTimeInterval(60)),
        "origin": "live",
        "card_id": cardID,
    ])
}

@MainActor
private final class FlakyWeatherDashboardSource: DashboardDataSource {
    let card: GenerativeUICard
    var shouldFail = false

    init(card: GenerativeUICard) {
        self.card = card
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        if shouldFail { throw DashboardFixtureError.unavailable }
        return DashboardSnapshot(
            weather: nil,
            inbox: [weatherItem(id: "weather", card: card)],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class SuspendedCleanupDashboardSource: DashboardDataSource {
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var cleanupStarted = false

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "closed-update",
                title: "Closed update",
                detail: "Cleanup must not block weather.",
                agentName: "Juno",
                status: "Complete",
                isSessionClosed: true,
                createdAt: Date()
            )],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        cleanupStarted = true
        await withCheckedContinuation { continuation in
            cleanupContinuation = continuation
        }
    }

    func waitUntilCleanupStarts() async {
        while !cleanupStarted { await Task.yield() }
    }

    func finishCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}

@MainActor
private final class ManagingDashboardSource: DashboardDataSource {
    struct BulkDismissal: Equatable {
        let types: [String]
        let createdBefore: Date
    }

    struct StateMutation: Equatable {
        let id: String
        let isRead: Bool
        let isPinned: Bool
    }

    var shouldFailMutations = false
    var removeFailedDismissalFromNextLoad = false
    private(set) var loadCount = 0
    private(set) var dismissedIDs: [String] = []
    private(set) var bulkDismissals: [BulkDismissal] = []
    private(set) var stateMutations: [StateMutation] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        return DashboardSnapshot(
            weather: nil,
            inbox: [
                DashboardInboxItem(
                    id: "update-1",
                    title: "One",
                    detail: "One",
                    agentName: "Juno",
                    status: "Now",
                    isRead: false,
                    isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 10)
                ),
                DashboardInboxItem(
                    id: "update-2",
                    title: "Two",
                    detail: "Two",
                    agentName: "Juno",
                    status: "Now",
                    isRead: false,
                    isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 20)
                ),
            ].filter {
                !removeFailedDismissalFromNextLoad || loadCount == 1 || $0.id != "update-1"
            },
            attentionItems: [
                DashboardAttentionItem(
                    id: "attention-1",
                    title: "Choose",
                    detail: "Choose",
                    urgency: .important,
                    createdAt: Date(timeIntervalSince1970: 30)
                )
            ],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        if shouldFailMutations { throw DashboardFixtureError.unavailable }
        dismissedIDs.append(id)
    }

    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws {
        if shouldFailMutations { throw DashboardFixtureError.unavailable }
        bulkDismissals.append(BulkDismissal(types: types, createdBefore: createdBefore))
    }

    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws {
        if shouldFailMutations { throw DashboardFixtureError.unavailable }
        stateMutations.append(.init(id: id, isRead: isRead, isPinned: isPinned))
    }
}

@MainActor
private final class DashboardApprovalResponseSource:
    DashboardDataSource, ApprovalRequestLoading, ApprovalClient {
    struct Submission: Equatable {
        let request: ApprovalRequest
        let decision: ApprovalDecision
    }

    let itemID = "approval.required:approval-1"
    let loaded = LoadedApprovalRequest(
        request: .vendorFixture,
        allowedDecisions: [.once, .session, .always, .deny]
    )
    private(set) var loadedIDs: [String] = []
    private(set) var submissions: [Submission] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [],
            attentionItems: [DashboardAttentionItem(
                id: itemID,
                title: "Approve session action",
                detail: "Hermes needs authorization",
                urgency: .important,
                approvalID: loaded.request.id,
                interaction: .approval(DashboardApprovalRequest(
                    eventID: itemID,
                    approvalID: loaded.request.id,
                    allowedDecisions: [.session],
                    expiresAt: Date(timeIntervalSince1970: 200)
                )),
                createdAt: Date(timeIntervalSince1970: 90)
            )],
            completedItems: [],
            agents: []
        )
    }

    func loadApproval(id: String) async throws -> LoadedApprovalRequest {
        loadedIDs.append(id)
        return loaded
    }

    func submit(
        request: ApprovalRequest,
        decision: ApprovalDecision
    ) async throws -> ApprovalReceipt {
        submissions.append(Submission(request: request, decision: decision))
        return ApprovalReceipt(requestID: request.id, decision: decision)
    }
}

@MainActor
private final class ChangingDashboardSource: DashboardDataSource {
    private(set) var loadCount = 0

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        return DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "update",
                title: "Update \(loadCount)",
                detail: "Current Hermes event data",
                agentName: "Hermes",
                status: "Just now"
            )],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class FlakyDashboardSource: DashboardDataSource {
    var shouldFail = false

    func loadDashboard() async throws -> DashboardSnapshot {
        if shouldFail {
            throw DashboardFixtureError.unavailable
        }
        return DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "stable-update",
                title: "Stable update",
                detail: "Keep this visible during a transient refresh failure.",
                agentName: "Juno",
                status: "Just now",
                createdAt: Date()
            )],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class RetentionDashboardSource: DashboardDataSource {
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [
                DashboardInboxItem(
                    id: "expired-update",
                    title: "Old update",
                    detail: "No longer useful",
                    agentName: "Hermes",
                    status: "Old",
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                DashboardInboxItem(
                    id: "fresh-update",
                    title: "Fresh update",
                    detail: "Still useful",
                    agentName: "Hermes",
                    status: "Now",
                    createdAt: Date()
                ),
            ],
            attentionItems: [
                DashboardAttentionItem(
                    id: "expired-decision",
                    title: "Old decision",
                    detail: "No longer actionable",
                    urgency: .important,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                DashboardAttentionItem(
                    id: "fresh-decision",
                    title: "Fresh decision",
                    detail: "Still actionable",
                    urgency: .important,
                    createdAt: Date()
                ),
            ],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class ClosedSessionDashboardSource: DashboardDataSource {
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [
                DashboardInboxItem(
                    id: "closed-update",
                    title: "Closed update",
                    detail: "Its session has ended",
                    agentName: "Hermes",
                    status: "Closed",
                    sessionID: "closed-session",
                    isSessionClosed: true,
                    createdAt: Date()
                ),
                DashboardInboxItem(
                    id: "open-update",
                    title: "Open update",
                    detail: "Its session is still active",
                    agentName: "Hermes",
                    status: "Now",
                    sessionID: "open-session",
                    createdAt: Date()
                ),
            ],
            attentionItems: [
                DashboardAttentionItem(
                    id: "closed-decision",
                    title: "Closed decision",
                    detail: "Its session has ended",
                    urgency: .important,
                    sessionID: "closed-session",
                    isSessionClosed: true,
                    createdAt: Date()
                ),
                DashboardAttentionItem(
                    id: "open-decision",
                    title: "Open decision",
                    detail: "Its session is still active",
                    urgency: .important,
                    sessionID: "open-session",
                    createdAt: Date()
                ),
            ],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class TerminalSessionDashboardSource: DashboardDataSource {
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "terminal-update",
                title: "Terminal update",
                detail: "Its session just completed",
                agentName: "Hermes",
                status: "Now",
                sessionID: "terminal-session",
                createdAt: Date()
            )],
            attentionItems: [DashboardAttentionItem(
                id: "terminal-decision",
                title: "Terminal decision",
                detail: "Its session just completed",
                urgency: .important,
                sessionID: "terminal-session",
                createdAt: Date()
            )],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class DeferredDashboardSource: DashboardDataSource {
    private var loadContinuation: CheckedContinuation<DashboardSnapshot, Error>?
    private var loadStarted = false

    func loadDashboard() async throws -> DashboardSnapshot {
        loadStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func waitUntilLoadStarts() async {
        while !loadStarted { await Task.yield() }
    }

    func resumeLoad(with snapshot: DashboardSnapshot) {
        loadContinuation?.resume(returning: snapshot)
        loadContinuation = nil
    }
}

@MainActor
private final class WeatherEnrichmentBaseSource: DashboardDataSource {
    var stateMutation: (String, Bool, Bool)?
    var dismissedID: String?

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "hermes-update",
                title: "Agent update",
                detail: "Hermes content remains intact",
                agentName: "Juno",
                status: "Now"
            )],
            attentionItems: [DashboardAttentionItem(
                id: "hermes-decision",
                title: "Review",
                detail: "A decision remains intact",
                urgency: .important
            )],
            completedItems: [DashboardCompletion(
                id: "hermes-completion",
                title: "Morning task",
                detail: "Completed successfully",
                agentName: "Juno",
                completedLabel: "Now"
            )],
            agents: []
        )
    }

    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws {
        stateMutation = (id, isRead, isPinned)
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedID = id
    }
}

@MainActor
private struct WeatherLoaderFixture: DashboardWeatherLoading {
    enum Error: Swift.Error {
        case unavailable
    }

    let result: Result<DashboardWeather?, Swift.Error>

    func loadCurrentWeather() async throws -> DashboardWeather? {
        try result.get()
    }
}

@MainActor
private final class WeatherLoaderSpy: DashboardWeatherLoading {
    let result: DashboardWeather?
    private(set) var loadCount = 0

    init(result: DashboardWeather?) {
        self.result = result
    }

    func loadCurrentWeather() async throws -> DashboardWeather? {
        loadCount += 1
        return result
    }
}

@MainActor
private final class DeferredWeatherLoader: DashboardWeatherLoading {
    private var continuation: CheckedContinuation<DashboardWeather?, any Error>?
    private var loadStarted = false
    private var loadFinished = false

    func loadCurrentWeather() async throws -> DashboardWeather? {
        loadStarted = true
        let weather = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        loadFinished = true
        return weather
    }

    func waitUntilLoadStarts() async {
        while !loadStarted { await Task.yield() }
    }

    func waitUntilLoadFinishes() async {
        while !loadFinished { await Task.yield() }
    }

    func resume(returning weather: DashboardWeather?) {
        continuation?.resume(returning: weather)
        continuation = nil
    }
}

@MainActor
private final class CountingDeferredWeatherLoader: DashboardWeatherLoading {
    private var continuations: [CheckedContinuation<DashboardWeather?, any Error>] = []
    private(set) var loadCount = 0

    func loadCurrentWeather() async throws -> DashboardWeather? {
        loadCount += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finishAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: DashboardWeather(city: "Device city", condition: "Clear",
                temperature: 61, high: 65, low: 52, systemImage: "sun.max.fill"))
        }
    }
}

@MainActor
private final class InterleavedDashboardSource: DashboardDataSource {
    private var continuations: [CheckedContinuation<DashboardSnapshot, any Error>] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilLoadStarts(count: Int) async {
        while continuations.count < count { await Task.yield() }
    }

    func resumeLoad(at index: Int, title: String) {
        continuations[index].resume(returning: Self.snapshot(title: title))
    }

    func failLoad(at index: Int, error: any Error) {
        continuations[index].resume(throwing: error)
    }

    private static func snapshot(title: String) -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "shared-update",
                title: title,
                detail: title,
                agentName: "Hermes",
                status: "Now"
            )],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class StaleDismissalDashboardSource: DashboardDataSource {
    private var loadCount = 0
    private var staleRefreshContinuation: CheckedContinuation<DashboardSnapshot, any Error>?

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        guard loadCount > 1 else { return Self.snapshot }
        return try await withCheckedThrowingContinuation { continuation in
            staleRefreshContinuation = continuation
        }
    }

    func dismissDashboardEvent(id: String) async throws {}

    func waitUntilStaleRefreshStarts() async {
        while staleRefreshContinuation == nil { await Task.yield() }
    }

    func finishStaleRefresh() {
        staleRefreshContinuation?.resume(returning: Self.snapshot)
        staleRefreshContinuation = nil
    }

    private static let snapshot = DashboardSnapshot(
        weather: nil,
        inbox: [
            DashboardInboxItem(
                id: "update-1",
                title: "Delete me",
                detail: "This row was dismissed.",
                agentName: "Hermes",
                status: "Now"
            ),
            DashboardInboxItem(
                id: "update-2",
                title: "Keep me",
                detail: "This row remains.",
                agentName: "Hermes",
                status: "Now"
            ),
        ],
        attentionItems: [],
        completedItems: [],
        agents: []
    )
}

@MainActor
private final class InterleavedCleanupDashboardSource: DashboardDataSource {
    private var loadCount = 0
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var cleanupStarted = false

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        if loadCount == 1 {
            return DashboardSnapshot(
                weather: nil,
                inbox: [DashboardInboxItem(
                    id: "shared-update",
                    title: "Closed update",
                    detail: "The old load will try to clean this up.",
                    agentName: "Hermes",
                    status: "Closed",
                    isSessionClosed: true,
                    createdAt: Date()
                )],
                attentionItems: [],
                completedItems: [],
                agents: []
            )
        }
        return DashboardSnapshot(
            weather: nil,
            inbox: [DashboardInboxItem(
                id: "shared-update",
                title: "Replacement update",
                detail: "This newer signal remains actionable.",
                agentName: "Hermes",
                status: "Now",
                createdAt: Date()
            )],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        cleanupStarted = true
        await withCheckedContinuation { continuation in
            cleanupContinuation = continuation
        }
    }

    func waitUntilLoadStarts(count: Int) async {
        while loadCount < count { await Task.yield() }
    }

    func waitUntilCleanupStarts() async {
        while !cleanupStarted { await Task.yield() }
    }

    func finishCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}

@MainActor
private struct ManySignalsDashboardSource: DashboardDataSource {
    let count: Int

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            weather: nil,
            inbox: (1...count).map { index in
                DashboardInboxItem(
                    id: "update-\(index)",
                    title: "Update \(index)",
                    detail: "Details for update \(index)",
                    agentName: "Hermes",
                    status: "Now"
                )
            },
            attentionItems: (1...count).map { index in
                DashboardAttentionItem(
                    id: "decision-\(index)",
                    title: "Decision \(index)",
                    detail: "Details for decision \(index)",
                    urgency: .important
                )
            },
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private func dashboardContentHeight(signalCount: Int) async throws -> CGFloat {
    let model = DashboardModel(source: ManySignalsDashboardSource(count: signalCount))
    await model.load()
    let controller = UIHostingController(rootView: DashboardView(model: model))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    await Task.yield()
    controller.view.layoutIfNeeded()
    return try #require(controller.view.descendants(of: UIScrollView.self).first).contentSize.height
}

private extension UIView {
    func descendants<View: UIView>(of type: View.Type) -> [View] {
        var matches = subviews.flatMap { $0.descendants(of: type) }
        if let match = self as? View { matches.insert(match, at: 0) }
        return matches
    }
}
