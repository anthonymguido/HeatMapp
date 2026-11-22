import SwiftUI

@main
struct WiFiHeatmapApp: App {
    @StateObject private var store = SurveyStore()

    var body: some Scene {
        WindowGroup {
            SurveyListView()
                .environmentObject(store)
                .task { LocationPermission.shared.requestIfNeeded() }
        }
    }
}
