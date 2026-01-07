// sam wiener 2025, all rights reserved

import Combine
import SwiftUI
import Repellent

class UserSettings: ObservableObject {
    static let shared = UserSettings()
    
    @AppStorage("downloadFolder") var downloadFolder: String = NSHomeDirectory() + "/Downloads"
    @AppStorage("resolution") var resolution: Resolution = .fhd
    @AppStorage("videoFormat") var videoFormat: VideoFormat = .mp4
    @AppStorage("audioFormat") var audioFormat: AudioFormat = .mp3
    @AppStorage("hdr") var hdr: Bool = false
    
    private init() {}
}
