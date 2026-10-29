import SwiftUI

@main
struct InstaApp: App {
    @StateObject private var store = ConfigStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
