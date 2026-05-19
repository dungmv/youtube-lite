//
//  Youtube_LiteApp.swift
//  Youtube Lite
//
//  Created by Mai Dũng on 9/4/26.
//

import SwiftUI
import AVFoundation

#if os(iOS)
import UIKit
#endif

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let orientationController = OrientationController()

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationController.supportedOrientations
    }
}

@MainActor
final class OrientationController {
    var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func setInlinePlayerMode() {
        supportedOrientations = .portrait
        rotateIfNeeded(to: .portrait)
    }

    func setFullscreenPlayerMode() {
        supportedOrientations = .landscape
        rotateIfNeeded(to: .landscapeRight)
    }

    private func rotateIfNeeded(to orientation: UIInterfaceOrientation) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
            return
        }

        if #available(iOS 16.0, *) {
            let preferences = UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations: supportedOrientations
            )
            try? scene.requestGeometryUpdate(preferences)
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        }

        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}
#endif

@main
struct Youtube_LiteApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
#if os(iOS) || os(visionOS)
        _ = PlaybackManager.shared
#endif
    }

    var body: some Scene {
        WindowGroup {
            VideoServiceView()
        }
    }
}
