import CoreLocation
import SwiftUI

struct WeatherPlace: Codable, Equatable, Identifiable {
    var name: String
    var detail: String = ""   // region and country, to tell Paris, France from Paris, Texas
    var latitude: Double
    var longitude: Double
    var id: String { "\(latitude),\(longitude)" }
}

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case system, celsius, fahrenheit
    var id: Self { self }
    var title: String { L(["system": "Automatic", "celsius": "Celsius", "fahrenheit": "Fahrenheit"][rawValue]!) }

    var usesFahrenheit: Bool {
        switch self {
        case .system: Locale.current.measurementSystem == .us
        case .celsius: false
        case .fahrenheit: true
        }
    }
}

struct WeatherReport: Equatable {
    struct Hour: Equatable, Identifiable {
        var time: Date
        var temperature: Double
        var code: Int
        var isDay: Bool
        var precipitation: Int
        var id: Date { time }
    }

    var temperature: Double
    var feelsLike: Double
    var code: Int
    var isDay: Bool
    var high: Double
    var low: Double
    var humidity: Int
    var wind: Double
    var hours: [Hour]
    var fetched = Date()
}

/// Forecasts from Open-Meteo: free, no account or API key, and nothing about you beyond the coordinates.
@Observable
final class WeatherStore: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherStore()
    private(set) var report: WeatherReport?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var locating = false
    private var timer: Timer?
    private var observingWake = false
    private var lastPlace: WeatherPlace?
    private var lastUnit: Bool?
    @ObservationIgnored private lazy var location: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        return manager
    }()

    func apply() {
        let prefs = Settings.shared.prefs
        let wanted = prefs.widgets.contains { $0.kind == .weather && $0.enabled }
        if wanted, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refresh() }
            if !observingWake {
                observingWake = true
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
                    if self?.timer != nil { self?.refresh() }
                }
            }
            refresh()
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
        // A new place or unit: fetch again now.
        if wanted, prefs.weatherPlace != lastPlace || prefs.temperatureUnit.usesFahrenheit != lastUnit { refresh() }
    }

    func refresh() {
        let prefs = Settings.shared.prefs
        lastPlace = prefs.weatherPlace
        lastUnit = prefs.temperatureUnit.usesFahrenheit
        guard let place = prefs.weatherPlace else { return }
        loading = true
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,relative_humidity_2m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "temperature_unit", value: prefs.temperatureUnit.usesFahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: prefs.temperatureUnit.usesFahrenheit ? "mph" : "kmh"),
        ]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, error in
            let report = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                // The place changed while this was loading: its answer is for somewhere else.
                guard let self, Settings.shared.prefs.weatherPlace == place else { return }
                self.loading = false
                if let report {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.report = report }
                    self.error = nil
                } else {
                    self.error = error?.localizedDescription ?? L("Weather is unavailable right now.")
                }
            }
        }.resume()
    }

    static func parse(_ data: Data) -> WeatherReport? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let hourly = json["hourly"] as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int else { return nil }
        let offset = json["utc_offset_seconds"] as? Int ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        // Arrays may hold nulls for hours without data: read them element by element.
        func numbers(_ key: String) -> [Double?] { (hourly[key] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue } }
        let times = (hourly["time"] as? [String] ?? []).map(formatter.date)
        let temps = numbers("temperature_2m"), codes = numbers("weather_code")
        let days = numbers("is_day"), rain = numbers("precipitation_probability")
        let now = Date().addingTimeInterval(-3600)
        let hours = times.indices.compactMap { i -> WeatherReport.Hour? in
            guard let time = times[i], time > now, i < temps.count, i < codes.count,
                  let temp = temps[i], let code = codes[i] else { return nil }
            return WeatherReport.Hour(time: time, temperature: temp, code: Int(code),
                                      isDay: i < days.count ? (days[i] ?? 1) == 1 : true,
                                      precipitation: i < rain.count ? Int(rain[i] ?? 0) : 0)
        }.prefix(8)
        return WeatherReport(temperature: temperature,
                             feelsLike: current["apparent_temperature"] as? Double ?? temperature,
                             code: code,
                             isDay: (current["is_day"] as? Int ?? 1) == 1,
                             high: (daily["temperature_2m_max"] as? [Double])?.first ?? temperature,
                             low: (daily["temperature_2m_min"] as? [Double])?.first ?? temperature,
                             humidity: current["relative_humidity_2m"] as? Int ?? 0,
                             wind: current["wind_speed_10m"] as? Double ?? 0,
                             hours: Array(hours))
    }

    // MARK: Places

    /// City search for Settings.
    static func search(_ query: String, done: @escaping ([WeatherPlace]) -> Void) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"),
                                 .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en")]
        URLSession.shared.dataTask(with: components.url!) { data, _, _ in
            let results = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["results"]
                as? [[String: Any]]) ?? []
            let places = results.compactMap { r -> WeatherPlace? in
                guard let name = r["name"] as? String, let lat = r["latitude"] as? Double,
                      let lon = r["longitude"] as? Double else { return nil }
                let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
                return WeatherPlace(name: name, detail: detail, latitude: lat, longitude: lon)
            }
            DispatchQueue.main.async { done(places) }
        }.resume()
    }

    /// One-off location lookup; asks for permission the first time.
    func useCurrentLocation() {
        error = nil
        locating = true
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locating = false
            error = L("Location access is off. Allow it in System Settings › Privacy & Security › Location Services.")
        default: location.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locating else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted:
            locating = false
            error = L("Location access is off. Allow it in System Settings › Privacy & Security › Location Services.")
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locating, let found = locations.last else { return }
        locating = false
        CLGeocoder().reverseGeocodeLocation(found) { placemarks, _ in
            let mark = placemarks?.first
            let place = WeatherPlace(name: mark?.locality ?? mark?.name ?? L("Current Location"),
                                     detail: [mark?.administrativeArea, mark?.country].compactMap { $0 }.joined(separator: ", "),
                                     latitude: found.coordinate.latitude, longitude: found.coordinate.longitude)
            DispatchQueue.main.async { Settings.shared.prefs.weatherPlace = place }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locating = false
        self.error = error.localizedDescription
    }

    // MARK: Codes

    /// WMO weather codes as SF Symbols.
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: "cloud.heavyrain.fill"
        case 95: "cloud.bolt.fill"
        case 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: L("Clear")
        case 1: L("Mostly Clear")
        case 2: L("Partly Cloudy")
        case 3: L("Cloudy")
        case 45, 48: L("Fog")
        case 51, 53, 55: L("Drizzle")
        case 56, 57: L("Freezing Drizzle")
        case 61, 63: L("Rain")
        case 65: L("Heavy Rain")
        case 66, 67: L("Freezing Rain")
        case 71, 73, 75, 77: L("Snow")
        case 80, 81: L("Showers")
        case 82: L("Heavy Showers")
        case 85, 86: L("Snow Showers")
        case 95: L("Thunderstorm")
        case 96, 99: L("Thunderstorm with Hail")
        default: "—"
        }
    }

    static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}

// MARK: - Widget

struct WeatherWidget: View {
    private var store = WeatherStore.shared

    var body: some View {
        let prefs = Settings.shared.prefs
        Group {
            if let place = prefs.weatherPlace, let report = store.report {
                content(place, report)
            } else if prefs.weatherPlace == nil {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 24))
                    Button("Choose a Place…") { SettingsWindowController.shared.show(pane: .widgets) }
                        .buttonStyle(BouncyButtonStyle())
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Pill().fill(.white.opacity(0.1)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    if store.loading { ProgressView().controlSize(.small) }
                    Text(store.error ?? L("Loading weather…")).font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if store.report == nil || store.report!.fetched.timeIntervalSinceNow < -1800 { store.refresh() } }
    }

    private func content(_ place: WeatherPlace, _ report: WeatherReport) -> some View {
        GeometryReader { geo in
            let hourCount = max(0, Int((geo.size.width - 4) / 40))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: WeatherStore.symbol(report.code, isDay: report.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 26))
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(WeatherStore.degrees(report.temperature))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .contentTransition(.numericText(value: report.temperature))
                            Text(place.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        }
                        Text("\(WeatherStore.description(report.code)) · H\(WeatherStore.degrees(report.high)) L\(WeatherStore.degrees(report.low))")
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if hourCount > 0 {
                    HStack(spacing: 0) {
                        ForEach(report.hours.prefix(hourCount)) { hour in
                            VStack(spacing: 2) {
                                Text(hour.time, format: .dateTime.hour()).font(.system(size: 8)).foregroundStyle(.secondary)
                                Image(systemName: WeatherStore.symbol(hour.code, isDay: hour.isDay))
                                    .symbolRenderingMode(.multicolor).font(.system(size: 11)).frame(height: 14)
                                Text(WeatherStore.degrees(hour.temperature)).font(.system(size: 9, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .help(hour.precipitation > 0 ? Text("\(hour.precipitation)% chance of rain") : Text(""))
                        }
                    }
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .help(Text("Feels like \(WeatherStore.degrees(report.feelsLike)) · Humidity \(report.humidity)%"))
    }
}

/// Settings: choose the place by search or current location, and the unit.
struct WeatherOptions: View {
    @Bindable private var settings = Settings.shared
    private var store = WeatherStore.shared
    @Local private var query = ""
    @Local private var results: [WeatherPlace] = []
    @Local private var searching = false

    var body: some View {
        if let place = settings.prefs.weatherPlace {
            LabeledContent("Place:") {
                Text(place.detail.isEmpty ? place.name : "\(place.name), \(place.detail)").lineLimit(2)
            }
        }
        LabeledContent("Find a city:") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("City", text: $query).onSubmit(search)
                    if searching { ProgressView().controlSize(.small) }
                }
                ForEach(results) { place in
                    Button {
                        settings.prefs.weatherPlace = place
                        results = []
                        query = ""
                    } label: {
                        Text(place.detail.isEmpty ? place.name : "\(place.name), \(place.detail)").lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        Button(store.locating ? "Locating…" : "Use My Location") { store.useCurrentLocation() }
            .disabled(store.locating)
        if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
        Picker("Units:", selection: $settings.prefs.temperatureUnit) {
            ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
        }
        Text("Forecasts by Open-Meteo.com. Only the place's coordinates are sent.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        WeatherStore.search(text) { places in
            searching = false
            results = places
        }
    }
}
