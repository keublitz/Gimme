// sam wiener 2026, all rights reserved

import Foundation
import Repellent
import SwiftUI

class BinaryManager {
    static var appBinDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let binDir = appSupport.appendingPathComponent("Gimme/bin")
        
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        
        return binDir
    }
    
    /// The deno binary manager.
    class Deno {
        // MARK: Base functions
        
        static func install(_ progress: Binding<String>) async throws {
            progress.wrappedValue = "Fetching deno download..."
            let downloadURL = try await fetchDownloadURL()
            console.log("URL: \(downloadURL.path)")
            let destURL = appBinDir.appendingPathComponent("deno")
            
            progress.wrappedValue = "Downloading deno binary..."
            let (tempZipURL, _) = try await URLSession.shared.download(from: downloadURL)
            let namedZipURL = tempZipURL
                .deletingLastPathComponent()
                .appendingPathComponent("deno_download.zip")
            // Clear zip if it already exists for some reason
            if FileManager.default.fileExists(atPath: namedZipURL.path) {
                try FileManager.default.removeItem(at: namedZipURL)
            }
            try FileManager.default.moveItem(at: tempZipURL, to: namedZipURL)
            
            // Delete temp .zip at the end
            defer { try? FileManager.default.removeItem(at: namedZipURL) }
            
            progress.wrappedValue = "Unzipping..."
            try unzip(namedZipURL, to: appBinDir)
            let installURL: URL = appBinDir.appendingPathComponent("deno")
            guard FileManager.default.fileExists(atPath: installURL.path) else {
                progress.wrappedValue = "An error occurred. Please try again."
                throw DenoError.binaryMissingAfterUnzip
            }
            
            progress.wrappedValue = "Installing..."
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: installURL.path
            )
            Grabber.shared.deno = installURL.path
        }
        
        static func update(_ progress: Binding<String>) async throws {
            guard binaryExists else {
                try await install(progress); return
            }
            
            guard let path = binaryPath else {
                console.log("Path for binary could not be found.", type: .error); return
            }
            
            progress.wrappedValue = "Updating deno..."
            
            var version = String()
            version = try await checkVersion() ?? "nil"
            
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = Process()
                    task.executableURL = URL(filePath: path)
                    task.arguments = ["upgrade"]
                    
                    DispatchQueue.main.async {
                        progress.wrappedValue = "Checking for latest deno version..."
                    }
                    
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    task.standardOutput = outPipe
                    task.standardError = errPipe
                    
                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        
                        if let output = String(data: data, encoding: .utf8) {
                            DispatchQueue.main.async {
                                output.split(separator: "\n").forEach { line in
                                    let lineStr = String(line)
//                                    version = "[\(lineStr)]"
                                    
                                    console.log("DENO UPDATE OUTPUT: \(lineStr)", type: .debug)
                                }
                            }
                        }
                        else {
                            console.log("No deno update output.", type: .debug)
                            return
                        }
                    }
                    
                    errPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        
                        if let error = String(data: data, encoding: .utf8) {
                            error.split(separator: "\n").forEach { line in
                                DispatchQueue.main.async {
//                                    version = "[\(String(line))]"
                                    console.log(String(line), type: .error)
                                }
                            }
                        }
                    }
                    
                    do {
                        try task.run()
                        task.waitUntilExit()
                        
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        
                        DispatchQueue.main.async {
                            progress.wrappedValue = "Updated deno! [\(version)]"
                        }
                        
                        cont.resume()
                    }
                    catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        
        static var binaryExists: Bool {
            let fm = FileManager.default
            
            // User-configured path check here
            
            let bundlePath = appBinDir.appendingPathComponent("deno").path
            if fm.fileExists(atPath: bundlePath) && fm.isExecutableFile(atPath: bundlePath) {
                console.log("Found Gimme download! \(bundlePath)")
                return true
            }
            
            // System path / common locations here
            
            return false
        }
        
        static var binaryPath: String? {
            let fm = FileManager.default
            
            // User-configured path check here
            
            let bundlePath = appBinDir.appendingPathComponent("deno").path
            if fm.isExecutableFile(atPath: bundlePath) { return bundlePath }
            
            // System path / common locations here
            
            return nil
        }
        
        // MARK: Assets
        
        /// The URL directing to the latest deno Github repo.
        private static let githubURL = URL(string: "https://api.github.com/repos/denoland/deno/releases/latest")!
        
        // MARK: Private helpers
        
        private static func fetchDownloadURL() async throws -> URL {
            let (data, _) = try await URLSession.shared.data(from: githubURL)
            
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            
#if arch(arm64)
            guard let asset = release.assets.first(where: { $0.name.contains("deno-aarch64-apple") && $0.name.hasSuffix(".zip") }),
                  let url = URL(string: asset.downloadURL) else {
                console.log("Could not find arch64 asset.", type: .error)
                throw InstallError.assetNotFound
            }
#else
            guard let asset = release.assets.first(where: { $0.name.contains("deno-x86_64-apple") && $0.name.hasSuffix(".zip") }),
                  let url = URL(string: asset.downloadURL) else {
                throw InstallError.assetNotFound
            }
#endif
            
            return url
        }
        
        private static func unzip(_ zip: URL, to dest: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", zip.path, "-d", dest.path]
            
            let stdPipe = Pipe()
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = stdPipe
            
            console.log("Running unzip process...", type: .debug)
            
            try process.run()
            process.waitUntilExit()
            
            stdPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                
                if let output = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        output.split(separator: "\n").forEach { line in
                            let lineStr = String(line)
                            console.log("UNZIP: \(lineStr)", type: .debug)
                        }
                    }
                }
            }
            
            if process.terminationStatus != 0 {
                let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error"
                
                throw DenoError.unzipFailed(errMsg)
            }
            
            console.log("Unzip complete!", type: .debug)
        }
        
        private static func checkVersion() async throws -> String? {
            guard let path = binaryPath, !path.isEmpty else {
                console.log("Could not retrieve deno binary path to check version.", type: .error)
                return nil
            }
            
            return try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = ["--version"]
                    
                    let std = Pipe()
                    let err = Pipe()
                    process.standardOutput = std
                    process.standardError = err
                    
                    try? process.run()
                    process.waitUntilExit()
                    
                    let output = String(data: std.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    
                    let formatted = output?
                        .components(separatedBy: "\n").first?
                        .components(separatedBy: " (").first?
                        .components(separatedBy: "deno ").last
                    
                    return cont.resume(returning: formatted)
                }
            }
        }
    }
    
    /// The yt-dlp binary manager.
    class YTDLP {
        // MARK: Base functions
        
        /// Downloads latest yt-dlp binary to Gimme/bin.
        static func install(_ progress: Binding<String>) async throws {
            progress.wrappedValue = "Fetching yt-dlp download..."
            let downloadURL = try await fetchDownloadURL()
            let destURL = appBinDir.appendingPathComponent("yt-dlp")
            
            progress.wrappedValue = "Downloading yt-dlp binary..."
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
            // Delete if already exists
            if FileManager.default.fileExists(atPath: destURL.path) {
                console.log("Already exists, overwriting...")
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            
            // Creating executable
            progress.wrappedValue = "Installing yt-dlp..."
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destURL.path
            )
            Grabber.shared.yt_dlp = destURL.path
            
            progress.wrappedValue = "yt-dlp install complete!"
        }
        
        /// Updates yt-dlp binary to the latest available version.
        static func update(_ progress: Binding<String>) async throws {
            guard binaryExists else {
                try await install(progress)
                return
            }
            
            guard let path = binaryPath else {
                console.log("Path for binary could not be found.", type: .error)
                return
            }
            
            progress.wrappedValue = "Updating yt-dlp..."
            
            var version = String()
            
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = Process()
                    task.executableURL = URL(filePath: path)
                    task.arguments = ["--update", "--version"]
                    
                    DispatchQueue.main.async {
                        progress.wrappedValue = "Checking for latest yt-dlp version..."
                    }
                    
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    task.standardOutput = outPipe
                    task.standardError = errPipe
                    
                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        
                        if let output = String(data: data, encoding: .utf8) {
                            DispatchQueue.main.async {
                                output.split(separator: "\n").forEach { line in
                                    let lineStr = String(line)
                                    version = "[\(lineStr)]"
                                    console.log("yt-dlp version after update: \(lineStr)", type: .debug)
                                }
                            }
                        }
                        else { return }
                    }
                    
                    errPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        
                        if let error = String(data: data, encoding: .utf8) {
                            error.split(separator: "\n").forEach { line in
                                DispatchQueue.main.async {
                                    console.log(String(line), type: .error)
                                }
                            }
                        }
                    }
                    
                    do {
                        try task.run()
                        task.waitUntilExit()
                        
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        
                        DispatchQueue.main.async {
                            progress.wrappedValue = "Updated yt-dlp! \(version)"
                        }
                        
                        cont.resume()
                    }
                    catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        
        /// Whether a yt-dlp binary exists on the user's device.
        static var binaryExists: Bool {
            let fm = FileManager.default
            
            // 1. Check user-configured path
            // ** THIS IS CURRENTLY A NON EXISTENT FUNCTION **
            console.log("Checking for user-installed yt-dlp...")
            if let saved = UserDefaults.standard.string(forKey: "ytDlpPath"),
               verifyBinary(at: saved) { console.log("Found user-installed!"); return true }
            
            // 2. Check for previous download from Gimme
            console.log("Checking for Gimme download...")
            let appBundled = appBinDir.appendingPathComponent("yt-dlp").path
            if fm.fileExists(atPath: appBundled) && fm.isExecutableFile(atPath: appBundled) { console.log("Found Gimme download! \(appBundled)"); return true }
            
        //    // 3. System path / common locations
        //    console.log("Checking for any other paths...")
        //    if let found = findBinary(named: "yt-dlp") ?? findBinaryInCommonPaths(named: "yt-dlp"),
        //       verifyBinary(at: found) { console.log("Found misc. path!"); return true }
            
            // Otherwise, show prompt for download
            console.log("No yt-dlp binary found on device.")
            return false
        }
        
        /// The file path of the yt-dlp binary.
        static var binaryPath: String? {
            let fm = FileManager.default
            
            // 1. User-configured path
            if let saved = UserDefaults.standard.string(forKey: "ytDlpPath"),
               verifyBinary(at: saved) { return saved }
            
            // 2. Gimme-downloaded binary
            let appBundled = appBinDir.appendingPathComponent("yt-dlp").path
            if fm.isExecutableFile(atPath: appBundled) { return appBundled }
            
            // 3. System/common paths
        //    if let found = findBinary(named: "yt-dlp") ?? findBinaryInCommonPaths(named: "yt-dlp") { return found }
                
            return nil
        }
        
        // MARK: Assets
        
        /// The URL directing to the latest yt-dlp Github repo.
        private static let githubURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        
        /// Fetches the direct download link from the yt-dlp Github repo.
        private static func fetchDownloadURL() async throws -> URL {
            let (data, _) = try await URLSession.shared.data(from: githubURL)
            
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            
            guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" }),
                  let url = URL(string: asset.downloadURL) else {
                throw InstallError.assetNotFound
            }
            
            return url
        }
        
        /// Returns the current yt-dlp version.
        private static func version() async -> String? {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let path = binaryPath else {
                        cont.resume(returning: nil)
                        return
                    }
                    
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = ["--version"]
                    
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = Pipe()
                    
                    try? process.run()
                    
                    let version = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    cont.resume(returning: version)
                }
            }
        }
        
        // MARK: Private helpers
        
        private static func verifyBinary(at path: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            }
            catch {
                return false
            }
        }
    }
    
    /// The ffmpeg binary manager.
    class FFmpeg {
        // MARK: Base functions
        
        /// Installs the ffmpeg binary.
        static func install(_ progress: Binding<String>, update: Bool = false) async throws {
            if !update {
                progress.wrappedValue = "Downloading ffmpeg..."
            }
            
            let (tempZipURL, _) = try await URLSession.shared.download(from: downloadURL)
            let namedZipURL = tempZipURL
                .deletingLastPathComponent()
                .appendingPathComponent("ffmpeg_download.zip")
            if FileManager.default.fileExists(atPath: namedZipURL.path) {
                try FileManager.default.removeItem(at: namedZipURL)
            }
            try FileManager.default.moveItem(at: tempZipURL, to: namedZipURL)
            
            // Delete temp .zip URL at the end
            defer { try? FileManager.default.removeItem(at: namedZipURL) }
            
            progress.wrappedValue = "Unzipping..."
            try unzip(namedZipURL, to: appBinDir)
            let installURL: URL = appBinDir.appendingPathComponent("ffmpeg")
            guard FileManager.default.fileExists(atPath: installURL.path) else {
                progress.wrappedValue = "An error occured. Please try again."
                throw FFmpegInstallError.binaryMissingAfterUnzip
            }
            
            progress.wrappedValue = "Installing..."
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: installURL.path
            )
            Grabber.shared.ffmpeg = installURL.path
            
            if !update {
                progress.wrappedValue = "ffmpeg install complete!"
            }
        }
        
        /// Updates the ffmpeg binary to the latest version.
        ///
        /// This function essentially reinstalls ffmpeg, as there is no direct update functionality built into ffmpeg distribution.
        static func update(_ progress: Binding<String>) async throws {
            progress.wrappedValue = "Checking for latest ffmpeg version..."
            try await install(progress, update: true)
            
            Task.detached(priority: .userInitiated) {
                let version = try await version() ?? "unknown ver."
                
                progress.wrappedValue = "Updated ffmpeg! [\(version)]"
            }
        }
        
        /// Whether an ffmpeg binary exists on the user's device.
        static var binaryExists: Bool {
            let fm = FileManager.default
            
            console.log("Checking for ffmpeg binary...")
            let bundlePath = appBinDir.appendingPathComponent("ffmpeg").path
            if fm.fileExists(atPath: bundlePath) && fm.isExecutableFile(atPath: bundlePath) {
                console.log("Found ffmpeg! \(bundlePath)")
                return true
            }
            
            console.log("No ffmpeg binary path found.", type: .warning)
            return false
        }
        
        /// The file path of the ffmpeg binary.
        static var binaryPath: String? {
            let fm = FileManager.default
            
            let bundlePath = appBinDir.appendingPathComponent("ffmpeg").path
            if fm.isExecutableFile(atPath: bundlePath) { return bundlePath }
            
            return nil
        }
        
        // MARK: Assets
        
        private static let downloadURL = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip")!
        
        private static func version() async throws -> String? {
            guard let path = binaryPath, !path.isEmpty else {
                console.log("Could not retrieve ffmpeg version, binary path is empty/nil.", type: .error)
                return nil
            }
            
            return try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments     = ["-version"]
                    
                    let std = Pipe()
                    let err = Pipe()
                    process.standardOutput = std
                    process.standardError  = err
                    
                    try? process.run()
                    process.waitUntilExit()
                    
                    let output = String(data: std.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    
                    let formatted = output?
                        .components(separatedBy: "\n").first?
                        .components(separatedBy: "version ").last?
                        .components(separatedBy: " ").first
                    
                    return cont.resume(returning: formatted)
                }
            }
        }
        
        // MARK: Helpers
        
        private static func unzip(_ zip: URL, to dest: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", zip.path, "-d", dest.path]
            
            let errPipe = Pipe()
            process.standardError = errPipe
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error"
                
                throw FFmpegInstallError.unzipFailed(errMsg)
            }
        }
    }
}

// MARK: - Miscellaneous

struct GitHubRelease: Codable {
    let assets: [GitHubAsset]
}

struct GitHubAsset: Codable {
    let name: String
    let downloadURL: String
    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

enum InstallError: Error {
    case assetNotFound
}

enum DenoError: LocalizedError {
    case binaryMissingAfterUnzip
    case unzipFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .binaryMissingAfterUnzip: return "deno binary not found after unzipping."
        case .unzipFailed(let err): return "Unzip failed: \(err)"
        }
    }
}

enum FFmpegInstallError: LocalizedError {
    case binaryMissingAfterUnzip
    case unzipFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .binaryMissingAfterUnzip: return "ffmpeg binary not found after unzipping."
        case .unzipFailed(let msg): return "Unzip failed: \(msg)"
        }
    }
}
