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

    @objc private func quitApplication() {
        NSApp.terminate(nil)
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

    private func statusBarImage() -> NSImage {
        let image = NSImage(named: "TrayIcon") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }
}
