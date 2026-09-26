import CoreLocation
import Foundation
import Testing
import WeatherKit
@testable import Loopdy

struct HomeWeatherServiceProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOPDY_LIVE_WEATHER_PROBE"] == "1"))
    func appleWeatherReturnsCurrentConditionsForPublicCoordinate() async throws {
        // Public downtown San Francisco coordinate, never a user's location.
        let weather = try await WeatherService.shared.weather(for: CLLocation(latitude: 37.7749, longitude: -122.4194))
        #expect(weather.currentWeather.temperature.value.isFinite)
        #expect(!weather.dailyForecast.forecast.isEmpty)
        let attribution = try await WeatherService.shared.attribution
        #expect(attribution.legalPageURL.scheme == "https")
        print("LIVE_WEATHER_PROBE: received current conditions and daily forecast with Apple attribution")
    }
}
