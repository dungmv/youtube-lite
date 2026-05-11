//
//  Youtube_LiteApp.swift
//  Youtube Lite
//
//  Created by Mai Dũng on 9/4/26.
//

import SwiftUI
import SwiftData
import AVFoundation

@main
struct Youtube_LiteApp: App {
    init() {
#if os(iOS) || os(visionOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ Audio session config failed: \(error.localizedDescription)")
        }
#endif
    }

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
        WindowGroup {
                    VideoServiceView()
                }
        .modelContainer(sharedModelContainer)
    }
}
