//
//  HookInstaller.swift
//  OpenCodeIsland
//
//  Auto-installs OpenCode plugin on app launch
//

import Foundation
import os.log

struct HookInstaller {
    private static let logger = Logger(subsystem: "com.opencodeisland", category: "HookInstaller")

    /// Install bundled plugin to OpenCode's plugin directory on app launch
    static func installIfNeeded() {
        // OpenCode plugins go in ~/.config/opencode/plugin/
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugin")
        let pluginFile = pluginDir.appendingPathComponent("opencode-island.js")

        logger.info("Installing plugin to: \(pluginDir.path, privacy: .public)")

        do {
            try FileManager.default.createDirectory(
                at: pluginDir,
                withIntermediateDirectories: true
            )
            logger.info("Created plugin directory")
        } catch {
            logger.error("Failed to create plugin directory: \(error.localizedDescription, privacy: .public)")
        }

        // Copy bundled plugin to user's plugin directory
        // Try multiple approaches to find the bundled resource
        var bundledPath: String? = Bundle.main.path(forResource: "opencode-island", ofType: "js")
        
        // Fallback: try direct path in Resources folder
        if bundledPath == nil {
            let directPath = Bundle.main.bundlePath + "/Contents/Resources/opencode-island.js"
            if FileManager.default.fileExists(atPath: directPath) {
                bundledPath = directPath
            }
        }
        
        if let path = bundledPath {
            logger.info("Found bundled plugin at: \(path, privacy: .public)")
            let bundled = URL(fileURLWithPath: path)
            
            do {
                if FileManager.default.fileExists(atPath: pluginFile.path) {
                    try FileManager.default.removeItem(at: pluginFile)
                    logger.info("Removed existing plugin")
                }
                try FileManager.default.copyItem(at: bundled, to: pluginFile)
                logger.info("Successfully installed plugin to: \(pluginFile.path, privacy: .public)")
            } catch {
                logger.error("Failed to copy plugin: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.error("Bundled plugin not found! Bundle path: \(Bundle.main.bundlePath, privacy: .public)")
            // List resources in bundle for debugging
            if let resourcePath = Bundle.main.resourcePath {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                    logger.info("Bundle resources: \(contents.joined(separator: ", "), privacy: .public)")
                } catch {
                    logger.error("Failed to list bundle resources")
                }
            }
        }
    }

    /// Check if plugin is currently installed
    static func isInstalled() -> Bool {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugin")
        let pluginFile = pluginDir.appendingPathComponent("opencode-island.js")

        return FileManager.default.fileExists(atPath: pluginFile.path)
    }

    /// Uninstall plugin
    static func uninstall() {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugin")
        let pluginFile = pluginDir.appendingPathComponent("opencode-island.js")

        try? FileManager.default.removeItem(at: pluginFile)
    }
}
