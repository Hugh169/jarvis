import Foundation

/// Forecasts via Open-Meteo.
///
/// The spec calls for WeatherKit, but that needs the `com.apple.developer.weatherkit`
/// entitlement tied to a registered App ID and a paid Apple Developer account —
/// impossible under the local self-signed identity this app builds with.
/// Open-Meteo needs no key and no account. Swapping to WeatherKit later means
/// replacing `execute` and nothing else.
public struct GetWeatherTool: JarvisTool {
    public static let name = "get_weather"
    public static let description = """
        Current conditions and daily forecast for a place. Defaults to Sydney. \
        Returns temperatures in Celsius.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "location": ["type": "string", "description": "Place name. Defaults to Sydney."],
            "days": ["type": "integer", "description": "Forecast days, 1 to 7. Default 2."],
        ],
    ]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private struct GeocodeResponse: Decodable {
        struct Place: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
            let country: String?
        }
        let results: [Place]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let wind_speed_10m: Double
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int?]
        }
        let current: Current
        let daily: Daily
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let placeName = input["location"]?.stringValue ?? "Sydney"
        let days = max(1, min(7, Int(input["days"]?.numberValue ?? 2)))

        guard let place = try await geocode(placeName) else {
            return .error("I couldn't find a place called \"\(placeName)\".")
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: String(days)),
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .error("The weather service didn't respond.")
        }
        let forecast = try JSONDecoder().decode(ForecastResponse.self, from: data)

        var lines = [
            "\(place.name): \(Self.describe(forecast.current.weather_code)), "
            + "\(Int(forecast.current.temperature_2m.rounded()))°C "
            + "(feels like \(Int(forecast.current.apparent_temperature.rounded()))°C), "
            + "wind \(Int(forecast.current.wind_speed_10m.rounded())) km/h."
        ]

        for index in 0..<min(days, forecast.daily.time.count) {
            let label = Self.dayLabel(forecast.daily.time[index], index: index)
            let high = Int(forecast.daily.temperature_2m_max[index].rounded())
            let low = Int(forecast.daily.temperature_2m_min[index].rounded())
            let rain = forecast.daily.precipitation_probability_max[index]
            let conditions = Self.describe(forecast.daily.weather_code[index])
            let rainText = rain.map { ", \($0)% chance of rain" } ?? ""
            lines.append("\(label): \(conditions), \(low) to \(high)°C\(rainText).")
        }

        return ToolResult(content: lines.joined(separator: "\n"))
    }

    private func geocode(_ name: String) async throws -> GeocodeResponse.Place? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: name),
            .init(name: "count", value: "1"),
        ]
        let (data, _) = try await session.data(from: components.url!)
        return try JSONDecoder().decode(GeocodeResponse.self, from: data).results?.first
    }

    private static func dayLabel(_ iso: String, index: Int) -> String {
        if index == 0 { return "Today" }
        if index == 1 { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: iso) else { return iso }
        return date.formatted(.dateTime.weekday(.wide))
    }

    /// WMO weather codes, in words the assistant can say aloud.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "clear"
        case 1: "mostly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "foggy"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61: "light rain"
        case 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71, 73, 75, 77: "snow"
        case 80, 81: "showers"
        case 82: "heavy showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorms"
        case 96, 99: "thunderstorms with hail"
        default: "unsettled"
        }
    }
}
