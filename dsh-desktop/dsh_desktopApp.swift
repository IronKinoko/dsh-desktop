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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let webService = DSHWebService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        webService.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        webService.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
