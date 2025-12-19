import Foundation
import CoreGraphics

enum SnapshotRenderScale {
  static let environmentKey = "SNAPSHOT_RENDER_SCALE"

  static func value(defaultScale: CGFloat) -> CGFloat {
    guard
      let raw = ProcessInfo.processInfo.environment[environmentKey],
      let value = Double(raw),
      value > 0
    else {
      return defaultScale
    }
    return CGFloat(value)
  }
}
