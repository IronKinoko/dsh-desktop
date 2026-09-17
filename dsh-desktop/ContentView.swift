//
//  ContentView.swift
//  dsh-desktop
//
//  Created by Kinoko on 2026/9/17.
//

import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var webService: DSHWebService

    var body: some View {
        Group {
            switch webService.state {
            case .starting:
                ProgressView("Starting dsh web...")
            case .running(let url):
                WebView(url: url)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Unable to start dsh web")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .padding(32)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
