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
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = """
            (() => {
              const style = document.createElement('style');
              style.textContent = `[data-slot="sidebar"] > div { padding-top: 26px !important; }`;
              document.head.appendChild(style);
            })();
            """
            webView.evaluateJavaScript(script)
        }
    }
}
