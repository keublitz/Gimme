// sam wiener 2025, all rights reserved

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: UserSettings
    
    @State private var grabber = Grabber()
    @State private var selectedLocation: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    
    var body: some View {
        VStack (alignment: .leading) {
            Picker("Preferred video format", selection: settings.$videoFormat) {
                ForEach(VideoFormat.allCases) { format in
                    Text(".\(format.rawValue)").tag(format)
                }
            }
            
            Picker("Maximum resolution", selection: settings.$resolution) {
                Text("2140p").tag(Resolution.uhd4k)
                Text("1440p").tag(Resolution.uhd)
                Text("1080p").tag(Resolution.fhd)
                Text("720p").tag(Resolution.hd)
                Text("480p").tag(Resolution.sd)
            }
            
            Toggle("HDR video (when supported)", isOn: settings.$hdr)
            
            Picker("Preferred audio format", selection: settings.$audioFormat) {
                ForEach(AudioFormat.allCases) { format in
                    Text(".\(format.rawValue)").tag(format)
                }
            }
            
            Button(action: {
                if let newLocation = selectDownloadLocation() {
                    selectedLocation = newLocation
                }
            }) {
                Text("Choose download folder")
            }
            Text("Current folder: \(selectedLocation.path)")
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button(action: {
                settings.resolution = .fhd
                settings.videoFormat = .mp4
                settings.audioFormat = .mp3
                settings.hdr = false
            }) {
                Text("Reset to Default")
            }
        }
        .frame(minWidth: 400, minHeight: 300, alignment: .topLeading)
        .padding()
    }
    
    private func selectDownloadLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Download Folder"
        panel.message = "Choose where to save videos and audio."
        
        if let folderPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = folderPath
        }
        
        if panel.runModal() == .OK {
            return panel.url
        }
        
        return nil
    }
}
