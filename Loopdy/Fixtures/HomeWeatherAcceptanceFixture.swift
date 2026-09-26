#if DEBUG
import Foundation

/// Explicit, public-data-only acceptance inputs. Never selected outside demo mode.
@MainActor
final class HomeWeatherAcceptanceFixture: DashboardDataSource, DashboardWeatherLoading {
    enum Failure: Error { case unavailable }
    let mode: String
    private var authorization: PermissionAuthorizationState
    private var attempts = 0

    init?(arguments: [String]) {
        guard let flag = arguments.first(where: { $0.hasPrefix("-home-weather-fixture=") }) else { return nil }
        let mode = String(flag.dropFirst("-home-weather-fixture=".count))
        guard ["permission", "denied", "failure", "offline", "ready"].contains(mode) else { return nil }
        self.mode = mode
        authorization = mode == "permission" ? .notDetermined : mode == "denied" ? .denied : .authorized
    }

    lazy var permissions = PermissionCenter(clients: [
        .locationWhenInUse: PermissionClient(
            status: { [self] in PermissionStatus(authorization: authorization) },
            request: { [self] in
                authorization = .authorized
                return PermissionStatus(authorization: authorization)
            }
        )
    ], isForeground: { true }, openSystemSettings: {})

    func loadDashboard() async throws -> DashboardSnapshot {
        if mode == "offline" { throw Failure.unavailable }
        let base = try await DashboardFixtureSource().loadDashboard()
        return DashboardSnapshot(weather: nil, inbox: base.inbox, attentionItems: base.attentionItems,
                                 completedItems: base.completedItems, agents: base.agents)
    }

    func loadCurrentWeather() async throws -> DashboardWeather? {
        guard authorization == .authorized else { return nil }
        attempts += 1
        if mode == "failure", attempts == 1 { throw Failure.unavailable }
        try await Task.sleep(for: .milliseconds(200))
        return DashboardWeather(city: "San Francisco", condition: "Clear", temperature: 61,
                                high: 65, low: 52, systemImage: "sun.max.fill", sourceName: "Demo weather")
    }
}
#endif
