// sam wiener 2026, all rights reserved

import Foundation
import Repellent
import SwiftUI

struct BundleInstaller {
    static let YTDlpGithubLink = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    
    static var appBinDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let binDir = appSupport.appendingPathComponent("Gimme/bin")
        
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        
        return binDir
    }
    
    static func fetchDownloadURL() async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: YTDlpGithubLink)
        
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" }),
              let url = URL(string: asset.downloadURL) else {
            throw InstallError.assetNotFound
        }
        
        return url
    }
    
    static func download(_ progress: Binding<String>) async throws -> String {
        console.log("Fetching link for download...")
        progress.wrappedValue = "Fetching yt-dlp download..."
        let downloadURL = try await fetchDownloadURL()
        let destURL = appBinDir.appendingPathComponent("yt-dlp")
        
        console.log("Downloading yt-dlp bundle...")
        progress.wrappedValue = "Downloading yt-dlp..."
        let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        
        console.log("Creating executable...")
        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destURL.path
        )
        
        Grabber.shared.yt_dlp = destURL.path
        
        console.log("yt-dlp download complete!")
        return destURL.path
    }
    
    static func update(_ progress: Binding<String>) async throws {
        guard await resolveYtDlp() else {
            try await download(progress)
            return
        }
        
        console.log("beginning update in global thread", type: .debug)
        progress.wrappedValue = "Checking for yt-dlp updates..."
        
        guard let path = resolvedYTDLPPath() else { return }
        
        let task = Process()
        task.executableURL = URL(filePath: path)
        
        task.arguments = [
            "--update"
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
            
            progress.wrappedValue = "Update complete!"
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }
        catch {
            console.catch(error)
        }
    }
}

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

func findBinary(named name: String) -> String? {
    // Check if binary exists at path first.
    if let userPath = UserDefaults.standard.string(forKey: "\(name)Path"),
       userPath.isExecutable() {
        return userPath
    }
    
    // Use `which` via shell (command unix command for finding executables)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe() // Suppress errors.
    
    try? process.run()
    process.waitUntilExit()
    
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    
    return (process.terminationStatus == 0 && !(output?.isEmpty ?? true)) ? output : nil
}

fileprivate extension String {
    func isExecutable() -> Bool {
        FileManager.default.isExecutableFile(atPath: self)
    }
}

let commonPaths = [
    "/usr/local/bin",       // Homebrew (Intel)
    "/opt/homebrew/bin",    // Homebrew (Apple silicon)
    "/usr/bin",
    "/usr/local/sbin",
    ("~/.local/bin" as NSString).expandingTildeInPath,
    ("/Applications/yt-dlp" as NSString).expandingTildeInPath
]

func findBinaryInCommonPaths(named name: String) -> String? {
    for dir in commonPaths {
        let fullPath = (dir as NSString).appendingPathComponent(name)
        if fullPath.isExecutable() {
            return fullPath
        }
    }
    
    return nil
}

func verifyBinary(at path: String) -> Bool {
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

func resolveYtDlp() async -> Bool {
    let fm = FileManager.default
    
    // 1. Check user-configured path
    console.log("Checking for user-installed yt-dlp...")
    if let saved = UserDefaults.standard.string(forKey: "ytDlpPath"),
       verifyBinary(at: saved) { console.log("Found user-installed!"); return true }
    
    // 2. Check for previous download from Gimme
    console.log("Checking for Gimme download...")
    let appBundled = BundleInstaller.appBinDir.appendingPathComponent("yt-dlp").path
    if fm.fileExists(atPath: appBundled) && fm.isExecutableFile(atPath: appBundled) { console.log("Found Gimme download! \(appBundled)"); return true }
    
//    // 3. System path / common locations
//    console.log("Checking for any other paths...")
//    if let found = findBinary(named: "yt-dlp") ?? findBinaryInCommonPaths(named: "yt-dlp"),
//       verifyBinary(at: found) { console.log("Found misc. path!"); return true }
    
    // Otherwise, show prompt for download
    console.log("No yt-dlp binary found on device.")
    return false
}

func resolvedYTDLPPath() -> String? {
    let fm = FileManager.default
    
    // 1. User-configured path
    if let saved = UserDefaults.standard.string(forKey: "ytDlpPath"),
       verifyBinary(at: saved) { return saved }
    
    // 2. Gimme-downloaded binary
    let appBundled = BundleInstaller.appBinDir.appendingPathComponent("yt-dlp").path
    if fm.isExecutableFile(atPath: appBundled) { return appBundled }
    
    // 3. System/common paths
//    if let found = findBinary(named: "yt-dlp") ?? findBinaryInCommonPaths(named: "yt-dlp") { return found }
        
    return nil
}
