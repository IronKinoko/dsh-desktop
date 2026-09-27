//
//  dsh_desktopApp.swift
//  dsh-desktop
//
//  Created by Kinoko on 2026/9/17.
//

import AppKit
import SwiftUI

@main
struct dsh_desktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Deepseek Harness", id: "main") {
            ContentView(webService: appDelegate.webService)
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let webService = DSHWebService()

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let updateMenu = NSMenu()
    private var versionTags: [DSHVersionTag] = []
    private var isLoadingVersionTags = false
    private var isUpdating = false
    private var updatingTag: DSHVersionTag?
    private let updateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        webService.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        webService.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            showMainWindow()
            return
        }

        statusItem?.menu = statusMenu
        sender.performClick(nil)
    }

    @objc private func restartWebService() {
        webService.restart()
    }

    @objc private func updateWebService(_ sender: NSMenuItem) {
        guard !isUpdating,
              let tagName = sender.representedObject as? String,
              let tag = versionTags.first(where: { $0.name == tagName })
        else {
            return
        }

        isUpdating = true
        updatingTag = tag
        rebuildUpdateMenu(placeholder: "Updating \(tag.name)...")
        showMainWindow()

        Task {
            do {
                try await webService.update(to: tag.name)
            } catch {
                showUpdateError(error)
            }

            isUpdating = false
            updatingTag = nil
            refreshVersionTags()
        }
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        refreshVersionTags()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = statusBarImage()
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusMenu.delegate = self
        statusMenu.addItem(
            NSMenuItem(
                title: "Restart",
                action: #selector(restartWebService),
                keyEquivalent: ""
            )
        )

        let updateMenuItem = NSMenuItem(
            title: "Update",
            action: nil,
            keyEquivalent: ""
        )
        updateMenuItem.submenu = updateMenu
        updateMenuItem.isEnabled = true
        statusMenu.addItem(updateMenuItem)
        rebuildUpdateMenu(placeholder: "Loading...")

        statusMenu.addItem(.separator())
        statusMenu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(quitApplication),
                keyEquivalent: "q"
            )
        )

        statusMenu.items.forEach { $0.target = self }
        self.statusItem = statusItem
    }

    private func refreshVersionTags() {
        guard !isLoadingVersionTags, !isUpdating else { return }

        isLoadingVersionTags = true
        if versionTags.isEmpty {
            rebuildUpdateMenu(placeholder: "Loading...")
        }

        Task {
            do {
                versionTags = try await webService.availableVersionTags()
                if !isUpdating {
                    rebuildUpdateMenu()
                }
            } catch {
                if versionTags.isEmpty {
                    rebuildUpdateMenu(placeholder: "Unable to load tags")
                }
            }

            isLoadingVersionTags = false
        }
    }

    private func rebuildUpdateMenu(placeholder: String? = nil) {
        updateMenu.removeAllItems()

        if isUpdating {
            if let updatingTag {
                updateMenu.addItem(
                    disabledMenuItem(title: "Updating \(updatingTag.name)...")
                )
            }
            return
        }

        if let placeholder {
            updateMenu.addItem(disabledMenuItem(title: placeholder))
            return
        }

        guard !versionTags.isEmpty else {
            updateMenu.addItem(disabledMenuItem(title: "No tags available"))
            return
        }

        for (index, tag) in versionTags.enumerated() {
            let item = NSMenuItem(
                title: "\(tag.name) \(tag.version)",
                action: #selector(updateWebService(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tag.name
            updateMenu.addItem(item)

            if let publishedAt = tag.publishedAt {
                updateMenu.addItem(
                    disabledMenuItem(
                        title: updateTimeFormatter.string(from: publishedAt)
                    )
                )
            }

            if index < versionTags.count - 1 {
                updateMenu.addItem(.separator())
            }
        }
    }

    private func disabledMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func showUpdateError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to update dsh"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func statusBarImage() -> NSImage {
        let image = NSImage(named: "TrayIcon") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }
}
