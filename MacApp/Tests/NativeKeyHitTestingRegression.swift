import Foundation
import CoreGraphics

@main struct NativeKeyHitTestingRegression {
    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 216)
        let cells = [
            CGRect(x: 0, y: 0, width: 40, height: 54),
            CGRect(x: 40, y: 0, width: 40, height: 54),
            CGRect(x: 20, y: 54, width: 40, height: 54),
            CGRect(x: 60, y: 54, width: 40, height: 54),
            CGRect(x: 0, y: 162, width: 100, height: 54),
            CGRect(x: 100, y: 162, width: 200, height: 54),
            CGRect(x: 300, y: 162, width: 100, height: 54),
        ]
        func hit(_ x: Double, _ y: Double) -> Int? {
            NativeKeyHitTesting.index(at: CGPoint(x: x, y: y), bounds: bounds, frames: cells)
        }
        precondition(hit(39, 25) == 0 && hit(40, 25) == 1, "Adjacent key boundary")
        precondition(NativeKeyHitTesting.index(at: CGPoint(x: 41, y: 25), bounds: bounds, frames: cells, retaining: 0) == 0, "Minor finger drift retains original key")
        precondition(NativeKeyHitTesting.index(at: CGPoint(x: 44, y: 25), bounds: bounds, frames: cells, retaining: 0) == 1, "Intentional slide crosses hysteresis margin")
        precondition(NativeKeyHitTesting.index(at: CGPoint(x: -1, y: 25), bounds: bounds, frames: cells, retaining: 0) == nil, "Retention must not accept contacts outside keyboard")
        precondition(NativeKeyHitTesting.index(at: CGPoint(x: 41, y: 25), bounds: bounds, frames: cells, retaining: 99) == 1, "Stale retained index falls back to hit testing")
        precondition(hit(2, 65) == 2 && hit(59, 65) == 2 && hit(60, 65) == 3, "Inset and gutter targets")
        precondition(hit(99, 190) == 4 && hit(100, 190) == 5 && hit(299, 190) == 5 && hit(300, 190) == 6, "Variable space/return boundary")
        precondition(hit(-1, 25) == nil && hit(401, 25) == nil && hit(25, -1) == nil && hit(25, 217) == nil, "Initial contacts outside surface must not insert")
        precondition(NativeKeyHitTesting.index(at: .zero, bounds: .zero, frames: []) == nil)
        precondition(NativeKeyHitTesting.index(at: CGPoint(x: 20, y: 20), bounds: bounds, frames: []) == nil)
        // Every point across an inset letter row must resolve to a key, including
        // visual gutters, so typing does not require hitting the cap's center.
        for x in 0..<400 { precondition(hit(Double(x), 65) != nil, "Dead zone at x=\(x)") }
        for width: CGFloat in [320, 375, 393, 430, 768] {
            let bottom = NativeKeyboardMetrics.bottomRow(width: width, y: 162, height: 54)
            let frames = [bottom.page, bottom.emoji, bottom.space, bottom.returnKey]
            precondition(bottom.emoji.width >= 44 && bottom.page.width >= 44)
            precondition(bottom.space.width > width * 0.45, "Space must retain the wide native typing target")
            precondition(bottom.returnKey.maxX == width && bottom.page.minX == 0)
            for pair in zip(frames, frames.dropFirst()) { precondition(pair.0.maxX == pair.1.minX) }
            for x in 0..<Int(width) {
                precondition(NativeKeyHitTesting.index(at: CGPoint(x: CGFloat(x), y: 190),
                    bounds: CGRect(x: 0, y: 0, width: width, height: 216), frames: frames) != nil)
            }
        }
        checkSpacebarTrackpad()
        print("Native key hit testing and spacebar trackpad regressions passed")
    }

    static func checkSpacebarTrackpad() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 216)
        let space = CGRect(x: 100, y: 162, width: 200, height: 54)
        let origin = CGPoint(x: 200, y: 190)
        func gesture() -> NativeSpacebarTrackpad {
            NativeSpacebarTrackpad(origin: origin, beganAt: 0, spaceFrame: space)
        }
        var tap = gesture()
        let tapped = tap.finish(at: origin, timestamp: 0.1, bounds: bounds)
        precondition(tapped.insertSpace && tapped.cursorOffset == 0, "A short Space tap must keep normal typing behavior")
        var held = gesture()
        precondition(held.move(to: origin, timestamp: 0.35, bounds: bounds) == 0 && held.isActive)
        let stationary = held.finish(at: origin, timestamp: 0.7, bounds: bounds)
        precondition(!stationary.insertSpace && stationary.cursorOffset == 0,
                     "Holding Space without moving must not insert a space")
        var drag = gesture()
        _ = drag.move(to: origin, timestamp: 0.35, bounds: bounds)
        precondition(drag.move(to: CGPoint(x: 207, y: 190), timestamp: 0.4, bounds: bounds) == 0)
        precondition(drag.move(to: CGPoint(x: 215, y: 190), timestamp: 0.5, bounds: bounds) == 1,
                     "Drag distance must accumulate across move events")
        precondition(drag.move(to: CGPoint(x: 216, y: 190), timestamp: 0.6, bounds: bounds) == 1)
        precondition(drag.move(to: CGPoint(x: 200, y: 190), timestamp: 0.7, bounds: bounds) == -2)
        precondition(drag.move(to: CGPoint(x: 200, y: 170), timestamp: 0.8, bounds: bounds) == 0,
                     "Vertical movement must not shift the text cursor")
        precondition(!drag.finish(at: origin, timestamp: 0.9, bounds: bounds).insertSpace)
        var quickDrift = gesture()
        precondition(quickDrift.move(to: CGPoint(x: 240, y: 190), timestamp: 0.2, bounds: bounds) == 0,
                     "Movement before the hold threshold must not move the cursor")
        precondition(quickDrift.finish(at: CGPoint(x: 240, y: 190), timestamp: 0.25, bounds: bounds).insertSpace)
        var cancelled = gesture()
        cancelled.cancel()
        let cancellation = cancelled.finish(at: origin, timestamp: 0.2, bounds: bounds)
        precondition(!cancellation.insertSpace && cancellation.cursorOffset == 0)
        var outside = gesture()
        _ = outside.move(to: origin, timestamp: 0.35, bounds: bounds)
        precondition(outside.move(to: CGPoint(x: 401, y: 190), timestamp: 0.5, bounds: bounds) == 0)
        precondition(outside.isCancelled)
        let returned = outside.finish(at: origin, timestamp: 0.6, bounds: bounds)
        precondition(!returned.insertSpace && returned.cursorOffset == 0,
                     "Leaving the keyboard must cancel the gesture even if the finger returns")
        var missed = gesture()
        precondition(!missed.finish(at: CGPoint(x: 320, y: 190), timestamp: 0.2, bounds: bounds).insertSpace)
    }
}
