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

enum VideoFormatExtension: String, CaseIterable, Identifiable, Codable {
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
    
    var binaryReady: Bool = false
    
    func recheckBinaries() {
        binaryReady = BinaryManager.YTDLP.binaryExists &&
        BinaryManager.FFmpeg.binaryExists &&
        BinaryManager.Deno.binaryExists
    }
    
    var yt_dlp: String
    var ffmpeg: String
    var deno: String
    
    var progress: Double = 0.0
    var status: String = ""
    var statusContext: String = ""
    var isDownloading: Bool = false
    
    var resolution: Resolution { settings.resolution }
    var videoFormat: VideoFormatExtension { settings.videoFormat }
    var audioFormat: AudioFormat { settings.audioFormat }
    var hdr: Bool { settings.hdr }
    
    private var conversionTimer: Timer?
    private var outputFilePath: String?
    private var lastFileSize: Int64 = 0
    private var fileSizeGrowthRate: Double = 0 // bytes per sec.
    private var estimatedFinalSize: Int64 = 0
    private var ext: String?
    
    private var currentTask: Process?
    
//    private func find_ffmpeg() -> String ? {
//        let possiblePaths = [
//            "/usr/local/bin/ffmpeg"
//        ]
//    }
    
    init() {
        guard let ytdlp = BinaryManager.YTDLP.binaryPath,
              let ffmpeg = BinaryManager.FFmpeg.binaryPath,
              let deno = BinaryManager.Deno.binaryPath else {
            console.log("One or more bundles could not be found, may need to be manually installed", type: .warning)
            self.yt_dlp = String()
            self.ffmpeg = String()
            self.deno = String()
            return
        }
        
        self.yt_dlp = ytdlp
        self.ffmpeg = ffmpeg
//        self.ffprobe = ffprobe
        self.deno = deno
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
    
    private var hdrStr: String { hdr ? "[dynamic_range^=HDR]" : "[dynamic_range^=SDR]" }
    
    private var bestAVC1Encoding: String { "bv*[height<=\(resStr)][vcodec^=avc1]+ba" }
    private var bestAnyEncodingHDR: String { "bv*[height<=\(resStr)][dynamic_range^=HDR]+ba" }
    private var bestAnyEncodingAnyHDR: String { "bv*[height<=\(resStr)]+ba" }
    private var bestAnyEncodingSDR: String { "bv*[height<=\(resStr)][dynamic_range^=SDR]+ba" }
    
    private var recode: [String] { ["--recode-video", "\(videoFormat.rawValue)"] }
    private var remux: [String] { ["--remux-video", "\(videoFormat.rawValue)"] }
    
    private func encodeInstructions(defaultTo fallback: String = "bv*+ba/b", ext: String? = nil) -> String {
        var inst: [String] = []
        
        var avc1EncodingIfNeeded: String {
            if let ext, ext == "mp4", settings.preferAVC1 {
                return bestAVC1Encoding
            }
            else {
                return bestAnyEncodingSDR
            }
        }
        
        switch videoFormat {
        case .mp4:
            if hdr {
                inst = [
                    bestAnyEncodingHDR,
                    bestAnyEncodingAnyHDR,
                    fallback
                ]
            } else {
                inst = [
                    avc1EncodingIfNeeded,
                    bestAnyEncodingSDR,
                    fallback
                ]
            }
        default: inst = [fallback]
        }
        
        return inst.joined(separator: "/")
    }
    
    private func getVideo(of url: String, ext: String? = nil, recode: Bool = true) -> [String] {
        var recodeRemux: String {
            switch recode {
            case true: return "--recode-video"
            case false: return "--remux-video"
            }
        }
        
        let bestAnyEncodingWithHDRPreference = "bv*[height<=\(resStr)]\(hdrStr)+ba/"
        let bestAnyEncodingAnyHDR = "bv*[height<=\(resStr)]+ba/"
        let best = "bv*+ba/b"
        
        let fallback = bestAnyEncodingWithHDRPreference + bestAnyEncodingAnyHDR + best
        
        return [
            "-f", encodeInstructions(defaultTo: fallback, ext: ext),
            "-o", "~/Downloads/%(title)s.%(ext)s",
            recodeRemux, "\(videoFormat.rawValue)",
            "--newline",
            url
        ]
    }
    
    private func createJSON(of url: String) -> [String] {
        return [
            "--print", VideoMetadata.jsonScript,
            "-f", encodeInstructions(),
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
    
    private var videoDownloadInProgress: Bool = false
    private var audioDownloadInProgress: Bool = false
    
    func fetchVideoMetadata(url: String) throws -> VideoMetadata {
        guard let ytDlpPath = BinaryManager.YTDLP.binaryPath else { return VideoMetadata() }
        
        let process = Process()
        process.executableURL = URL(filePath: ytDlpPath)
        process.arguments = createJSON(of: url)
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        try process.run()
//        process.waitUntilExit()
        
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode(VideoMetadata.self, from: data)
    }
    
    private var metadata: VideoMetadata?
    
    func fetchMetadata(url: String) {
        do {
            let decoded = try fetchVideoMetadata(url: url)
            
            metadata = decoded
            console.log("Set metadata.", type: .success)
            estimatedFinalSize = Int64(decoded.filesize_approx)
            console.log("Set estimated final size: \(estimatedFinalSize).", type: .success)
            ext = decoded.ext
            console.log("Set extension: \(ext).", type: .success)
        }
        catch {
            console.catch(error)
        }
    }
    
    enum ProcessError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let string) = self { return string }
            return nil
        }
    }
    
    func update() {
        DispatchQueue.global(qos: .userInitiated).async {
            console.log("beginning update in global thread", type: .debug)
            
            guard let path = BinaryManager.YTDLP.binaryPath else { return }
            
            let task = Process()
            task.executableURL = URL(filePath: path)
            
            task.arguments = [
                "--ffmpeg-location", self.ffmpeg, "--update"
            ]
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe
            
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8) {
                    output.split(separator: "\n").forEach { line in
                        let lineStr = String(line)
                        console.log(lineStr, type: .debug)
                    }
                }
            }
            
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let error = String(data: data, encoding: .utf8) {
                    error.split(separator: "\n").forEach { line in
                        console.log(String(line), type: .error)
                    }
                }
            }
            
            do {
                try task.run()
                task.waitUntilExit()
                
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
            }
            catch {
                console.catch(error)
            }
        }
    }
    
    var ffmpegStats: [String: String] = [:]
    
    let progressFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("encode_progress_\(UUID().uuidString).txt")
    
    private func monitorFFmpegProgress(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        
        let fd = open(url.path, O_RDONLY)
        guard fd != -1 else {
            console.log("fd == -1", type: .error)
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .global()
        )
        
        var offset: UInt64 = 0
        var stats: [String: String] = [:]
        
        source.setEventHandler {
            let handle = FileHandle(fileDescriptor: fd)
            try? handle.seek(toOffset: offset)
            let newData = handle.availableData
            offset += UInt64(newData.count)
            
            guard let text = String(data: newData, encoding: .utf8) else {
                console.log("Could not create text from progress data.", type: .error)
                return
            }
            
            for line in text.components(separatedBy: "\n") {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                
                if line.hasPrefix("progress=") {
                    if let outTimeStr = stats["out_time"],
                       let currentSeconds = parseTimeToSeconds(outTimeStr),
                       let speedStr = stats["speed"]?.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces),
                       let speed = Double(speedStr), speed > 0,
                       let metadata = self.metadata {
                        
                        let percent = min(currentSeconds / Double(metadata.duration), 1.0)
                        let remainingMediaSeconds = max(Double(metadata.duration) - currentSeconds, 0)
                        let remainingRealSeconds = remainingMediaSeconds / speed
                        
                        let percentInt = Int(percent * 100)
                        
                        DispatchQueue.main.async {
                            self.status = "Encoding... \(percentInt)% | \(remainingRealSeconds.remaining()) remaining"
                            self.progress = percent
                        }
                    }
                    
                    // OLD
//                    let outTime = stats["out_time"] ?? "?"
//                    let speed = stats["speed"] ?? "?"
//                    
//                    DispatchQueue.main.async {
//                        self.status = "Encoding... \(outTime) at \(speed)"
//                    }
                    
                    if line == "progress=end" {
                        source.cancel()
                        try? FileManager.default.removeItem(at: url)
                    }
                    
                    stats = [:]
                }
                else if line.contains("=") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 { stats[parts[0]] = parts[1] }
                }
            }
        }
        
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    
    func download(url: String, filetype: FileType = .video) {
        DispatchQueue.main.async {
            self.isDownloading = true
            self.progress = 0.0
            self.status = "Preparing (may take around 30 seconds)..."
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            console.log("download initiated (in global thread)", type: .debug)
            
            self.fetchMetadata(url: url)
            
            var exporter: [String] {
                switch filetype {
                case .audio: return self.getAudio(of: url)
                case .video:
//                    let ext = self.videoFormat.rawValue
                    
                    console.log("Found extension (\(self.ext)). Based on this information, yt-dlp will \(self.ext == self.videoFormat.rawValue ? "remux" : "recode") the video to \(self.videoFormat.rawValue).", type: .success)
                    return self.getVideo(of: url, ext: self.ext ?? String(), recode: self.ext != self.videoFormat.rawValue || (self.ext != "mp4" && !self.settings.preferAVC1))
                }
            }
            
            guard let ytDlpPath = BinaryManager.YTDLP.binaryPath else {
                console.log("No yt-dlp path found, aborting download.", type: .error)
                return
            }
            
            let task = Process()
            task.executableURL = URL(filePath: ytDlpPath)
            self.currentTask = task
            
            task.arguments = [
                "--ffmpeg-location", self.ffmpeg,
                "--js-runtimes", "deno:\(self.deno)",
                "--postprocessor-args", "VideoConvertor:-progress \(self.progressFileURL.path)"
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
                                for ext in VideoFormatExtension.allCases {
                                    if lineStr.hasSuffix(ext.rawValue) {
                                        self.videoDownloadInProgress = true
                                        self.audioDownloadInProgress = false
                                    }
                                }
                                
                                for ext in AudioFormat.allCases {
                                    if lineStr.hasSuffix(ext.rawValue) {
                                        self.audioDownloadInProgress = true
                                        self.videoDownloadInProgress = false
                                    }
                                }
                                
                                var currentTypeDownloading: String? {
                                    if self.videoDownloadInProgress {
                                        return "video"
                                    } else if self.audioDownloadInProgress {
                                        return "audio"
                                    } else {
                                        return nil
                                    }
                                }
                                
                                if let current = currentTypeDownloading {
                                    self.status = "Downloading \(current)... \(String(lineStr.trimmingPrefix("[download] ")))"
                                } else {
                                    self.status = "Downloading... " + String(lineStr.trimmingPrefix("[download] "))
                                }
                            }
                        }
                        
                        if lineStr.contains("[VideoConvertor]") || lineStr.contains("[VideoRemuxer]") {
                            if let destinationRange = lineStr.range(of: "Destination: (.+)$", options: .regularExpression) {
                                self.outputFilePath = String(lineStr[destinationRange])
                                    .replacingOccurrences(of: "Destination: ", with: "")
                            }
                            
                            DispatchQueue.main.async {
                                self.status = "Encoding video..."
//                                self.startMonitoringConversion()
                                self.monitorFFmpegProgress(at: self.progressFileURL)
                            }
                        }
                        
                        if lineStr == "progress=continue" || lineStr == "progress=end" {
                            DispatchQueue.main.async {
                                self.status = "Encoding... time: \(self.ffmpegStats["out_time"] ?? "?") speed: \(self.ffmpegStats["speed"] ?? "?")"
                            }
                            self.ffmpegStats = [:]
                        }
                        else if lineStr.contains("=") && !lineStr.contains("[") {
                            let parts = lineStr.split(separator: "=", maxSplits: 1).map(String.init)
                            
                            if parts.count == 2 {
                                self.ffmpegStats[parts[0]] = parts[1]
                            }
                        }
                        
                        DispatchQueue.main.async {
                            console.log(lineStr, simple: true)
                        }
                    }
                }
            }
            
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let error = String(data: data, encoding: .utf8) {
                    error.split(separator: "\n").forEach { line in
                        DispatchQueue.main.async {
                            console.log(String(line), type: .error)
                        }
                        
                        let str = String(line)
                        
                        if str.contains("Sign in to confirm you’re not a bot.") {
                            self.statusContext = "YouTube is temporarily blocking automatic downloads. Please try again later."
                        }
                        
                        if str.contains("Requested format is not available.") {
                            self.statusContext = "This video does not support downloads in the chosen format."
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
                        console.log("Download successful!", type: .success)
                    } else {
                        self.status = "Failed"
                        console.log("Download failed", type: .error)
                    }
                    self.invalidateTimer()
                    self.estimatedFinalSize = 0
                    self.lastFileSize = 0
                    self.fileSizeGrowthRate = 0
                    self.fileSizeDeltas = []
                    self.outputFilePath = nil
                    self.videoDownloadInProgress = false
                    self.audioDownloadInProgress = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.invalidateTimer()
                    self.estimatedFinalSize = 0
                    self.lastFileSize = 0
                    self.fileSizeGrowthRate = 0
                    self.fileSizeDeltas = []
                    self.outputFilePath = nil
                    self.videoDownloadInProgress = false
                    self.audioDownloadInProgress = false
                    
                    self.isDownloading = false
                    self.status = "Error"
                    console.catch(error)
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
                        console.log("Total download size: \(String(format: "%.2f", mb))", type: .debug)
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
        
        let unit = String(str[unitRange]).uppercased()
        
        let multiplier: Double
        switch unit {
        case "B", "BYTES": multiplier = 1
        case "KB", "KIB": multiplier = 1_024
        case "MB", "MIB": multiplier = 1_024 * 1_024
        case "GB", "GIB": multiplier = 1_073_741_824
        case "TB", "TIB": multiplier = 1_099_511_627_776
        default: return nil
        }
        
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
        console.log("timers are gone: \(conversionTimer == nil)")
    }
    
    private var fileSizeDeltas: [Double] = []
    
    private func updateConversionProgress() {
        guard let path = outputFilePath else { return }
        
        let expandedPath = (path as NSString).expandingTildeInPath
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: expandedPath),
           let fileSize = attrs[.size] as? Int64 {
            
            if lastFileSize > 0 {
                let sizeDelta = fileSize - lastFileSize
                
                fileSizeDeltas.append(Double(sizeDelta))
                
                let uniqueDeltas = Set(fileSizeDeltas)
                
                if uniqueDeltas.count > 25 {
                    fileSizeDeltas.removeFirst()
                }
                
                let avgDelta = uniqueDeltas.reduce(0, +) / Double(uniqueDeltas.count)
                fileSizeGrowthRate = avgDelta
                
                var diff: Double { 2 }
                
                let targetSize = estimatedFinalSize > 0 ? Int64(Double(estimatedFinalSize) * diff) : fileSize * 2
                
                console.log("targetSize = \(targetSize), formatted = \(targetSize / 1_048_576)MB, estimatedFinalSize = \(estimatedFinalSize)", simple: true)
                console.log("estimatedFinalSize * diff (\(diff)) = \(Double(estimatedFinalSize) * diff)", simple: true)
                console.log("filesize * 2 = \(fileSize * 2)", simple: true)
                
                let progress = min(Double(fileSize) / Double(targetSize), 0.99)
                
                if fileSizeGrowthRate > 0 {
                    let remainingBytes = targetSize - fileSize
                    let estimatedSecondsRemaining = Int(Double(remainingBytes) / fileSizeGrowthRate)
                    
                    let mins = estimatedSecondsRemaining / 60
                    let secs = estimatedSecondsRemaining % 60
                    
                    var remaining: String {
                        if mins == 0 {
                            return "\(secs)s remaining"
                        } else {
                            return "\(mins)m \(secs)s remaining"
                        }
                    }
                    
                    let progressPercent = Int(progress * 100)
                    self.progress = Double(progress)
                    
                    if fileSizeDeltas.count <= 10 {
                        self.status = "Encoding... \(progressPercent)% | Estimating time remaining..."
                    } else if secs >= 0 {
                        self.status = "Encoding... \(progressPercent)% | \(remaining)"
                    } else {
                        let mbSize = Double(fileSize) / 1_048_576
                        self.status = "Encoding... \(progressPercent)% | Almost ready... (\(String(format: "%.1f", mbSize))MB)"
                    }
                } else {
                    let mbSize = Double(fileSize) / 1_048_576
                    self.status = "Encoding... \(String(format: "%.1f", mbSize))MB"
                }
            } else {
                self.status = "Encoding..."
            }
            
            lastFileSize = fileSize
        }
    }
    
    func cancel() {
        currentTask?.terminate()
        currentTask = nil
        
        if let path = outputFilePath {
            let expanded = (path as NSString).expandingTildeInPath
            try? FileManager.default.removeItem(atPath: expanded)
            try? FileManager.default.removeItem(atPath: expanded + ".part")
        }
        
        DispatchQueue.main.async {
            self.isDownloading = false
            self.destinationsTouched = 0
            self.progress = 0
            self.status = "Cancelled."
            self.invalidateTimer()
            self.estimatedFinalSize = 0
            self.lastFileSize = 0
            self.fileSizeGrowthRate = 0
            self.fileSizeDeltas = []
            self.outputFilePath = nil
            self.videoDownloadInProgress = false
            self.audioDownloadInProgress = false
        }
    }
}
