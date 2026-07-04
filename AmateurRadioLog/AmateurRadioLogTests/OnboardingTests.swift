import XCTest
import SwiftData
@testable import AmateurRadioLog

/// Trigger logic for the first-run onboarding flow (item: real onboarding).
@MainActor
final class OnboardingTests: XCTestCase {

    // MARK: - shouldPresent predicate

    func testFreshInstallShowsOnboarding() {
        XCTAssertTrue(OnboardingView.shouldPresent(
            stationCallsign: "", hasCompletedOnboarding: false))
    }

    func testUpgraderWithCallsignNeverSeesOnboarding() {
        XCTAssertFalse(OnboardingView.shouldPresent(
            stationCallsign: "W2ASM", hasCompletedOnboarding: false))
        XCTAssertFalse(OnboardingView.shouldPresent(
            stationCallsign: "W2ASM", hasCompletedOnboarding: true))
    }

    /// The old setup sheet reappeared on every launch for SWL users with no
    /// callsign; the completion flag must suppress it after one skip.
    func testSWLUserWhoSkippedIsNotNaggedAgain() {
        XCTAssertFalse(OnboardingView.shouldPresent(
            stationCallsign: "", hasCompletedOnboarding: true))
    }

    // MARK: - AppSettings flag

    /// New field must default to false (CloudKit-safe defaulted addition)
    /// and round-trip through the store.
    func testHasCompletedOnboardingDefaultsFalseAndPersists() throws {
        let container = try ModelContainer(
            for: AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let settings = AppSettings.shared(context: context)
        XCTAssertFalse(settings.hasCompletedOnboarding)

        settings.hasCompletedOnboarding = true
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AppSettings>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched.first?.hasCompletedOnboarding ?? false)
    }
}
