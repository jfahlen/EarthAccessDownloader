//
//  EarthAccessDownloaderApp.swift
//  EarthAccessDownloader
//
//  Created by Jay Fahlen on 10/21/26.
//

import AppKit
import SwiftUI

@main
struct EarthAccessDownloaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { SearchViewModel.cleanUpQuicklooks() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    SearchViewModel.cleanUpQuicklooks()
                }
        }
        .defaultSize(width: 1100, height: 800)
    }
}
