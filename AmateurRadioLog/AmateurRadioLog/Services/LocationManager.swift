import Foundation
import CoreLocation

@MainActor
@Observable
final class LocationManager: NSObject {
    var currentGrid: String?
    var isLocating = false
    var errorMessage: String?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func requestLocation() {
        isLocating = true
        errorMessage = nil

        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(macOS)
            manager.requestAlwaysAuthorization()
            #else
            manager.requestWhenInUseAuthorization()
            #endif
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            isLocating = false
            errorMessage = "Location access denied. Enable in Settings."
        @unknown default:
            isLocating = false
            errorMessage = "Unknown location authorization status"
        }
    }

    /// One-shot location fix (same flow as `locationToGrid()`, but returns
    /// the raw location for consumers that need coordinates — e.g. the
    /// nearest-park lookup). Also refreshes `currentGrid`.
    func currentLocation() async -> CLLocation? {
        isLocating = true
        errorMessage = nil

        let location = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont

            switch manager.authorizationStatus {
            case .notDetermined:
                #if os(macOS)
                manager.requestAlwaysAuthorization()
                #else
                manager.requestWhenInUseAuthorization()
                #endif
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            default:
                cont.resume(returning: nil)
                self.continuation = nil
            }
        }

        isLocating = false

        guard let location else {
            if errorMessage == nil {
                errorMessage = "Location access denied. Enable in Settings."
            }
            return nil
        }

        currentGrid = MaidenheadConverter.toGrid(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        return location
    }

    func locationToGrid() async -> String? {
        isLocating = true
        errorMessage = nil

        let location = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont

            switch manager.authorizationStatus {
            case .notDetermined:
                #if os(macOS)
                manager.requestAlwaysAuthorization()
                #else
                manager.requestWhenInUseAuthorization()
                #endif
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            default:
                cont.resume(returning: nil)
                self.continuation = nil
            }
        }

        isLocating = false

        guard let location else {
            if errorMessage == nil {
                errorMessage = "Location access denied. Enable in Settings."
            }
            return nil
        }

        let grid = MaidenheadConverter.toGrid(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        currentGrid = grid
        return grid
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(returning: location)
            } else if let location {
                self.currentGrid = MaidenheadConverter.toGrid(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
                self.isLocating = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = error.localizedDescription
            self.isLocating = false
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(returning: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            let authorized: Bool
            #if os(macOS)
            authorized = manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
            #else
            authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
            #endif
            if authorized && self.isLocating {
                manager.requestLocation()
            }
        }
    }
}
