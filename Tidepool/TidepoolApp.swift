//
//  TidepoolApp.swift
//  Tidepool
//
//  Created by Connor White on 8/7/25.
//

import SwiftUI
import UIKit

@main
struct TidepoolApp: App {
    @StateObject private var favoritesManager = InAppFavoritesManager()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register background task for visit uploads
        VisitDetector.shared.registerBackgroundTask()

        // UINavigationBar titles
        let navAppearance = UINavigationBarAppearance()
        if let titleDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline).withDesign(.rounded) {
            let titleFont = UIFont(descriptor: titleDescriptor, size: 0)
            navAppearance.titleTextAttributes = [.font: titleFont]
        }
        if let largeDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle).withDesign(.rounded) {
            let largeFont = UIFont(descriptor: largeDescriptor, size: 0)
            navAppearance.largeTitleTextAttributes = [.font: largeFont]
        }
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        // UITabBarItem titles
        if let tabFontDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .footnote).withDesign(.rounded) {
            let tabFont = UIFont(descriptor: tabFontDescriptor, size: 0)
            let attrs: [NSAttributedString.Key: Any] = [.font: tabFont]
            UITabBarItem.appearance().setTitleTextAttributes(attrs, for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes(attrs, for: .selected)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favoritesManager)
                .fontDesign(.rounded)
                .environment(\.font, .system(.body, design: .rounded))
                .task {
                    #if DEBUG
                    // Always re-auth in debug to ensure fresh token against local server
                    print("[App] Debug auth: attempting against local server...")
                    BackendClient.shared.logout() // clear any stale credentials
                    do {
                        try await BackendClient.shared.debugAuthenticate()
                        print("[App] Debug auth: SUCCESS, isAuthenticated=\(BackendClient.shared.isAuthenticated)")
                    } catch {
                        print("[App] Debug auth: FAILED - \(error.localizedDescription)")
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        VisitDetector.shared.startBatchUploads()
                    case .background:
                        VisitDetector.shared.stopBatchUploads()
                        VisitDetector.shared.scheduleBackgroundUpload()
                    default:
                        break
                    }
                }
        }
    }
}
