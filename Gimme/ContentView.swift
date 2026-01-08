// sam wiener 2025, all rights reserved

import SwiftUI

struct ContentView: View {
    let grabber = Grabber.shared
    
    @State private var urlInput: String = ""
    @State private var showSettings: Bool = false
    
    var body: some View {
        VStack {
            TextField("Type video URL here", text: $urlInput)
                .padding(.horizontal)
                .lineLimit(1)
            Button("Gimme the video") {
                grabber.download(url: urlInput, filetype: .video)
            }
            .disabled(grabber.isDownloading)
            Button("Gimme the audio") {
                grabber.download(url: urlInput, filetype: .audio)
            }
            .disabled(grabber.isDownloading)
            
            if grabber.isDownloading || grabber.progress == 1.0 || grabber.status == "Failed" || grabber.status == "Error" {
                loadingBar
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
            .frame(width: 300)
        }
    }
    
    private func clamp(_ value: Double, _ mnm: Double = 0.0, _ mxm: Double = 1.0) -> Double {
        return max(mnm, min(mxm, value))
    }
}

#Preview {
    ContentView()
}
