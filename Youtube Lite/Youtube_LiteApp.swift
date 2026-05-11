//
//  Youtube_LiteApp.swift
//  Youtube Lite
//
//  Created by Mai Dũng on 9/4/26.
//

import SwiftUI
import AVFoundation

@main
struct Youtube_LiteApp: App {
    init() {
#if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            print("✅ Audio session configured for background playback")
        } catch {
            print("⚠️ Audio session config failed: \(error.localizedDescription)")
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            VideoServiceView()
        }
    }
}
