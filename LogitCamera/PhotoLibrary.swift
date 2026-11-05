@preconcurrency import Photos

enum PhotoLibrary {
    static func save(_ photo: CapturedPhoto) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited
        else { throw CameraFailure.photoPermission }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: photo.data, options: nil)
        }
    }
}
