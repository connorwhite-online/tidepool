//
//  TidepoolApp.swift
//  Tidepool
//
//  Created by Connor White on 8/7/25.
//

import SwiftUI

@main
struct TidepoolApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
