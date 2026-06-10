// sam wiener 2026, all rights reserved

import Foundation
import Repellent
import SwiftUI

struct FFmpegInstaller {
    // API returning direct link to latest release
    private static let downloadURL = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip")!
    
    private static var appBinDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let binDir = appSupport.appendingPathComponent("Gimme/bin")
        
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        
        return binDir
    }
    
    private static var installedPath: URL { appBinDir.appendingPathComponent("ffmpeg") }
    
    // MARK: - Install
    
    static func install(_ progress: Binding<String>) async throws -> String {
        console.log("Downloading ffmpeg...", type: .info)
        progress.wrappedValue = "Downloading ffmpeg..."
        
        let (tempZipURL, _) = try await URLSession.shared.download(from: downloadURL)
        
        // Rename to .zip to conform to unzip
        let namedZipURL = tempZipURL.deletingLastPathComponent().appendingPathComponent("ffmpeg_download.zip")
        if FileManager.default.fileExists(atPath: namedZipURL.path) {
            try FileManager.default.removeItem(at: namedZipURL)
        }
        try FileManager.default.moveItem(at: tempZipURL, to: namedZipURL)
        // Delete temp URL at the end
        defer { try? FileManager.default.removeItem(at: namedZipURL) }
        
        progress.wrappedValue = "Unzipping package..."
        try unzip(namedZipURL, to: appBinDir)
        
        guard FileManager.default.fileExists(atPath: installedPath.path) else {
            progress.wrappedValue = "An error occurred, please try again."
            throw FFmpegInstallError.binaryMissingAfterUnzip
        }
        
        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedPath.path
        )
        
        Grabber.shared.ffmpeg = installedPath.path
        
        progress.wrappedValue = "ffmpeg download complete!"
        return installedPath.path
    }
    
    // MARK: - Unzip function
    
    private static func unzip(_ zipURL: URL, to destURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = [
            "-o",               // overwrite without prompting
            "-q",               // quiet (no debugging)
            zipURL.path,
            "-d", destURL.path
        ]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errMsg = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw FFmpegInstallError.unzipFailed(errMsg)
        }
    }
}

// MARK: - Throw errors

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
