import CoreGraphics
import Observation

/// Measured once per display change; the hardware camera area is never interactive.
struct IslandLayout: Equatable {
    var cameraWidth: CGFloat = 180
    var cameraHeight: CGFloat = 0
    // Hide the folded silhouette just inside the hardware bounds, including
    // the anti-aliased edge, instead of leaving a hairline under the camera.
    var foldedWidth: CGFloat { max(0, cameraWidth - 4) }
    var foldedHeight: CGFloat { max(0, cameraHeight - 2) }

    var recordingWidth: CGFloat { max(260, cameraWidth + 64) }
    var recordingHeight: CGFloat { 46 }
    var panelSize: CGSize {
        CGSize(width: max(416, recordingWidth + 40), height: cameraHeight + 324)
    }
    @MainActor func surfaceSize(notice: IslandNotice?) -> CGSize {
        CGSize(
            width: notice == nil ? recordingWidth : max(376, recordingWidth),
            height: cameraHeight + (notice?.height ?? recordingHeight))
    }
}

/// Shared presentation state; audio capture never depends on reveal animations.
@MainActor @Observable
final class IslandPresentation {
    var expanded = false
    var notice: IslandNotice?
    var layout = IslandLayout()
}
