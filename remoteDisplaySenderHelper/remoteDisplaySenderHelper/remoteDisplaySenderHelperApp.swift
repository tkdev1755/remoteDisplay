//
//  remoteDisplaySenderHelperApp.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 17/02/2026.
//

import SwiftUI
import SwiftData

@main
struct remoteDisplaySenderHelperApp: App {
    @StateObject private var manager = ThunderboltManager()
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
    
        MenuBarExtra("", systemImage : "circle"){
            ContentView(manager: manager)
        }
        .menuBarExtraStyle(.window)
        
    }
}
