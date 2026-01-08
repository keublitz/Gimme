// sam wiener 2025, all rights reserved

import Combine
import Foundation
import SwiftUI
import AppKit
import Repellent

enum FileType {
    case video
    case audio
}

enum Resolution: String, CaseIterable, Identifiable, Codable {
    case uhd4k
    case uhd
    case fhd
    case hd
    case sd
    
    var id: String { self.rawValue }
}

enum VideoFormat: String, CaseIterable, Identifiable, Codable {
    case avi
    case flv
    case mkv
    case mp4
    case mov
    case webm
    
    var id: String { self.rawValue }
}

enum AudioFormat: String, CaseIterable, Identifiable, Codable {
    case aac
    case alac
    case flac
    case m4a
    case mp3
    case opus
    case vorbis
    case wav
    
    var id: String { self.rawValue }
}

@Observable
class Grabber {
    static let shared = Grabber()
    let settings = UserSettings.shared
    
    let yt_dlp: String
    let ffmpeg: String
//    let ffprobe: String
//    let deno: String
    
    var progress: Double = 0.0
    var status: String = ""
    var isDownloading: Bool = false
    
    var resolution: Resolution { settings.resolution }
    var videoFormat: VideoFormat { settings.videoFormat }
    var audioFormat: AudioFormat { settings.audioFormat }
    var hdr: Bool { settings.hdr }
    
    private var conversionStartTime: Date?
    private var conversionTimer: Timer?
    private var outputFilePath: String?
    private var lastFileSize: Int64 = 0
    private var fileSizeGrowthRate: Double = 0 // bytes per sec.
    private var estimatedFinalSize: Int64 = 0
    
//    private func find_ffmpeg() -> String ? {
//        let possiblePaths = [
//            "/usr/local/bin/ffmpeg"
//        ]
//    }
    
    init() {
        guard let ytdlp = Bundle.main.path(forResource: "yt-dlp", ofType: nil),
              let ffmpeg = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
//              let ffprobe = Bundle.main.path(forResource: "ffprobe", ofType: nil) else {
            Debugger.fatalError("one or more bundles could not be found")
        }
        
        self.yt_dlp = ytdlp
        self.ffmpeg = ffmpeg
//        self.ffprobe = ffprobe
//        self.deno = deno
    }
    
    private var resStr: String {
        switch resolution {
        case .uhd4k: return "2160"
        case .uhd: return "1440"
        case .fhd: return "1080"
        case .hd: return "720"
        case .sd: return "480"
        }
    }
    
    private func getBestMP4(of url: String) -> [String] {
        let height = "[height<=\(resStr)]"
        let hdrStr = hdr ? "[dynamic_range^=HDR]" : "[dynamic_range^=SDR]"
        let vcodec = hdr ? "[vcodec!^=av01]" : "[vcodec^=avc1]"
        
        return [
            "-f", "bv\(height)\(vcodec)\(hdrStr)+ba/b\(height)\(vcodec)/b\(height)[vcodec^=avc1]/b\(height)[vcodec!^=av01]/b\(height)/w",
            "--recode-video", "mp4",
            "-o", "~/Downloads/%(title)s.%(ext)s",
            "--newline",
            url
        ]
    }
    
    private func getVideo(of url: String) -> [String] {
        let height = "[height<=\(resStr)]"
        let hdrStr = hdr ? "[dynamic_range^=HDR]" : "[dynamic_range^=SDR]"
        let codec = "[vcodec!^=av01]"
        
        return [
            "-f", "bv\(height)\(hdrStr)\(codec)+ba/b\(height)\(hdrStr)\(codec)/b\(height)\(codec)/w",
            "--recode-video", "\(videoFormat.rawValue)",
            "-o", "~/Downloads/%(title)s.%(ext)s",
            "--newline",
            url
        ]
    }
    
    private func getBestMP3(of url: String) -> [String] {
        [
            "-f", "ba",
            "-x",
            "--audio-format", "mp3",
            "--audio-quality", "0",
            "-o", "~/Downloads/%(title)s.%(ext)s",
            "--newline",
            url
        ]
    }
    
    private func getAudio(of url: String) -> [String] {
        [
            "-f", "ba",
            "-x",
            "--audio-format", "\(audioFormat.rawValue)",
            "--audio-quality", "0",
            "-o", "~/Downloads/%(title)s.%(ext)s",
            "--newline",
            url
        ]
    }
    
    func download(url: String, filetype: FileType = .video) {
        DispatchQueue.main.async {
            self.isDownloading = true
            self.progress = 0.0
            self.status = "Preparing..."
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            Debugger.log("download initiated (in global thread)", type: .debug)
            
            let task = Process()
            task.executableURL = URL(filePath: self.yt_dlp)
            
            var exporter: [String] {
                switch filetype {
                case .audio: return self.getAudio(of: url)
                case .video:
                    if self.videoFormat == .mp4 {
                        return self.getBestMP4(of: url)
                    }
                    return self.getVideo(of: url)
                }
            }
            
            task.arguments = [
                "--ffmpeg-location", self.ffmpeg,
//                "--js-runtimes", "deno:\(self.deno)"
            ] + exporter
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe
            
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8) {
                    output.split(separator: "\n").forEach { line in
                        let lineStr = String(line)
                        
                        if lineStr.contains("Extracting") {
                            self.status = "Fetching video..."
                        }
                        
                        if lineStr.contains("[download]") {
                            self.parseProgress(ofType: filetype, from: lineStr)
                            
                            if lineStr.contains("as required by the site") {
                                let splitLine = lineStr.split(separator: " ")
                                let sleep = splitLine[2]
                                
                                self.status = "Ready to start in about \(sleep) seconds..."
                            } else {
                                if lineStr.starts(with: "[download] 100") {
                                    self.status = "Finishing up..."
                                } else {
                                    self.status = String(lineStr.trimmingPrefix("[download] "))
                                }
                            }
                        }
                        
                        if lineStr.contains("[VideoConvertor]") {
                            if let destinationRange = lineStr.range(of: "Destination: (.+)$", options: .regularExpression) {
                                self.outputFilePath = String(lineStr[destinationRange])
                                    .replacingOccurrences(of: "Destination: ", with: "")
                            }
                            
                            DispatchQueue.main.async {
                                self.conversionStartTime = Date()
                                self.status = "Converting video..."
                                self.startMonitoringConversion()
                            }
                        }
                        
                        DispatchQueue.main.async {
                            Debugger.log(lineStr, simple: true)
                        }
                    }
                }
            }
            
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let error = String(data: data, encoding: .utf8) {
                    error.split(separator: "\n").forEach { line in
                        DispatchQueue.main.async {
                            Debugger.log(String(line), type: .error)
                        }
                    }
                }
            }
            
            do {
                try task.run()
                task.waitUntilExit()
                
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.destinationsTouched = 0
                    if task.terminationStatus == 0 {
                        self.progress = 1.0
                        self.status = "Complete!"
                        Debugger.log("Download successful!", type: .success)
                    } else {
                        self.status = "Failed"
                        Debugger.log("Download failed", type: .error)
                    }
                    self.invalidateTimer()
                    self.estimatedFinalSize = 0
                    self.lastFileSize = 0
                    self.fileSizeGrowthRate = 0
                    self.outputFilePath = nil
                    self.conversionStartTime = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.invalidateTimer()
                    self.estimatedFinalSize = 0
                    self.lastFileSize = 0
                    self.fileSizeGrowthRate = 0
                    self.outputFilePath = nil
                    self.conversionStartTime = nil
                    
                    self.isDownloading = false
                    self.status = "Error"
                    Debugger.catch(error)
                }
            }
        }
    }
    
    private var destinationsTouched: Int = 0
    
    private func parseProgress(ofType filetype: FileType, from line: String) {
        let pattern = #"([0-9.]+)%.*?of\s+([0-9.]+[A-Za-z]+).*?at\s+([0-9.]+[A-Za-z/s]+).*?ETA\s+([0-9:]+)"#
        
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let percentRange = Range(match.range(at: 1), in: line),
               let percent = Double(line[percentRange]) {
                DispatchQueue.main.async {
                    self.progress = percent / 100
//                    self.status = "\(Int(postPct))%"
                }
            }
            
            if let sizeRange = Range(match.range(at: 2), in: line) {
                let str = String(line[sizeRange])
                if let bytes = self.parseSize(str) {
                    if estimatedFinalSize == 0 {
                        self.estimatedFinalSize = bytes
                    }
                    
                    DispatchQueue.main.async {
                        let mb = Double(self.estimatedFinalSize) / 1_048_576
                        Debugger.log("Total download size: \(String(format: "%.2f", mb))", type: .debug)
                    }
                }
            }
        }
    }
    
    private func parseSize(_ str: String) -> Int64? {
        let pattern = #"([0-9.]+)([A-Za-z]+)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let numberRange = Range(match.range(at: 1), in: str),
              let unitRange = Range(match.range(at: 2), in: str),
              let number = Double(str[numberRange]) else {
            return nil
        }
        
        Debugger.log("====== PARSE SIZE OPERATIONS =======", simple: true)
        Debugger.log("regex: \(regex)", simple: true)
        Debugger.log("match: \(match)", simple: true)
        Debugger.log("numberRange: \(numberRange)", simple: true)
        Debugger.log("unitRange: \(unitRange)", simple: true)
        Debugger.log("number: \(number)", simple: true)
        
        let unit = String(str[unitRange]).uppercased()
        
        Debugger.log("unit: \(unit)", simple: true)
        
        let multiplier: Double
        switch unit {
        case "B", "BYTES": multiplier = 1
        case "KB", "KIB": multiplier = 1_024
        case "MB", "MIB": multiplier = 1_024 * 1_024
        case "GB", "GIB": multiplier = 1_073_741_824
        case "TB", "TIB": multiplier = 1_099_511_627_776
        default: return nil
        }
        
        Debugger.log("FINAL RESULT: \(number * multiplier)", simple: true)
        Debugger.log("==> which should end up as \((number * multiplier) / 1_048_576)")
        
        return Int64(number * multiplier)
    }
    
    private func startMonitoringConversion() {
        conversionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateConversionProgress()
        }
    }
    
    private func invalidateTimer() {
        conversionTimer?.invalidate()
        conversionTimer = nil
        Debugger.log("timers are gone: \(conversionTimer == nil)")
    }
    
    private func updateConversionProgress() {
        guard let path = outputFilePath,
              let startTime = conversionStartTime else { return }
        
        let expandedPath = (path as NSString).expandingTildeInPath
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: expandedPath),
           let fileSize = attrs[.size] as? Int64 {
            
            let elapsed = -startTime.timeIntervalSinceNow
            
            if lastFileSize > 0 {
                let sizeDelta = fileSize - lastFileSize
                fileSizeGrowthRate = Double(sizeDelta)
                
                // very crude estimate assuming final is 1.5x source
                let targetSize = estimatedFinalSize > 0 ? estimatedFinalSize : fileSize * 2
                
                Debugger.log("targetSize = \(targetSize / 1_048_576)MB, estimatedFinalSize = \(estimatedFinalSize)", type: .debug)
                
                let progress = min(Double(fileSize) / Double(targetSize), 0.99)
                
                if fileSizeGrowthRate > 0 {
                    let remainingBytes = targetSize - fileSize
                    let estimatedSecondsRemaining = Int(Double(remainingBytes) / fileSizeGrowthRate)
                    
                    let mins = estimatedSecondsRemaining / 60
                    let secs = estimatedSecondsRemaining % 60
                    
                    let progressPercent = Int(progress * 100)
                    self.status = "Converting... \(progressPercent)% | ~\(mins)m \(secs)s remaining)"
                } else {
                    let mbSize = Double(fileSize) / 1_048_576
                    self.status = "Converting... \(String(format: "%.1f", mbSize))MB"
                }
            } else {
                self.status = "Converting..."
            }
            
            lastFileSize = fileSize
        }
    }
}
