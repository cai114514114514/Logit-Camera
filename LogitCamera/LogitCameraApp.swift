import SwiftUI

@main
struct LogitCameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .tint(.yellow)
        }
    }
}
