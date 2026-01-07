// sam wiener 2025, all rights reserved
// started on 12/31/25

import SwiftUI

@main
struct Gimme: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        Settings {
            SettingsView()
                .environmentObject(UserSettings.shared)
        }
    }
}
