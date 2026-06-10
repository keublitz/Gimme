// sam wiener 2025, all rights reserved

import SwiftUI
import OSLog

struct ContentView: View {
    let grabber = Grabber.shared
    
    @State private var urlInput: String = ""
    @State private var showSettings: Bool = false
    
    @State private var message = "Checking for packages..."
    @State private var metadata = VideoMetadata()
    
    @State private var ffmpegInstallStatus = String()
    @State private var ytdlpInstallStatus = String()
    
    var body: some View {
        VStack {
            TextField("Type video URL here", text: $urlInput)
                .padding(.horizontal)
                .lineLimit(1)
                .onAppear {
                    logger.log("Testing out the logger.")
                    logger.error("This is what an error looks like.")
                    logger.critical("This is what a REALLY bad error looks like.")
                }
            Button("Gimme the video") {
                grabber.download(url: urlInput, filetype: .video)
            }
            .disabled(grabber.isDownloading || message != "✅ Ready!")
            Button("Gimme the audio") {
                grabber.download(url: urlInput, filetype: .audio)
            }
            .disabled(grabber.isDownloading || message != "✅ Ready!")
            
//            Button("Fetch metadata (DEBUG)") {
//                Task.detached {
//                    self.metadata = try await grabber.fetchVideoMetadata(url: urlInput)
//                }
//            }
            
//            Button("update") {
//                Task.detached { await grabber.update() }
//            }
            
            if grabber.isDownloading || grabber.progress == 1.0 || grabber.status == "Failed" || grabber.status == "Error" {
                loadingBar
            }
            
//            Text(ffmpegInstallStatus)
//                .font(.footnote)
//            Text(ytdlpInstallStatus)
//                .font(.footnote)
//            
//            Text(metadata.format_id)
//            Text(metadata.vcodec)
//            Text(metadata.ext)
//            Text(metadata.resolution)
//            Text(metadata.dynamic_range)
//            Text("\(metadata.filesize_approx.size(in: .mb)) MB")
            
            Spacer()
            
            HStack {
                Text(message)
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .task {
            message = "Checking packages..."
            await grabber.recheckBinaries()
            
            if !grabber.binaryReady {
                message = "Downloading packages..."
                Task.detached {
                    try await FFmpegInstaller.install($message)
                    try await BundleInstaller.update($message)
                    
                    await grabber.recheckBinaries()
                    
                    if !grabber.binaryReady {
                        message = "❌ An error occurred downloading packages. Click \"Download/Update Packages\" in Settings to try again."
                    } else {
                        message = "✅ Ready!"
                    }
                }
            }
            else {
                message = "✅ Ready!"
            }
        }
        .padding()
    }
    
    private var loadingBar: some View {
        VStack {
            ProgressView(value: clamp(grabber.progress)) {
                EmptyView()
            } currentValueLabel: {
                if !grabber.statusContext.isEmpty {
                    Text(grabber.statusContext)
                } else {
                    Text(grabber.status)
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 400)
        }
    }
    
    let logger = Logger(subsystem: "com.gimme", category: "installer")
    
    private func downloadText() -> String {
        if grabber.binaryReady {
            return "✅ Ready!"
        }
        else {
            return "❌ Some packages are missing. Click \"Download/Update Packages\" in the settings to continue."
        }
    }
    
    private func clamp(_ value: Double, _ minimum: Double = 0.0, _ maximum: Double = 1.0) -> Double {
        return max(minimum, min(maximum, value))
    }
}

extension Int {
    func size(in sizeFormat: ByteUnits, decimalPoints: Int = 2) -> Double {
        let bytes = self
        let kilobytes = Double(bytes) / 1024.0
        let megabytes = kilobytes / 1024.0
        let gigabytes = megabytes / 1024.0
        
        switch sizeFormat {
        case .bytes: return Double(bytes)
        case .kb: return kilobytes
        case .mb: return megabytes
        case .gb: return gigabytes
        }
    }
}

enum ByteUnits {
    case bytes
    case kb
    case mb
    case gb
}


#Preview {
    ContentView()
}
