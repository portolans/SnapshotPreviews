//
//  UIKitRenderingStrategy.swift
//
//
//  Created by Noah Martin on 7/5/24.
//

#if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
import Foundation
import UIKit
import SwiftUI

public class UIKitRenderingStrategy: RenderingStrategy {

  public init(a11yWrapper: ((UIViewController, UIWindow, PreviewLayout) -> UIView)? = nil) {
    let windowScene = UIApplication.shared
      .connectedScenes
      .filter { $0.activationState == .foregroundActive }
      .first ?? UIApplication.shared.connectedScenes.first

    let window = windowScene != nil ? UIWindow(windowScene: windowScene as! UIWindowScene) : UIWindow()
    window.windowLevel = .statusBar + 1
    window.backgroundColor = UIColor.systemBackground
    window.makeKeyAndVisible()
    self.window = window
    self.a11yWrapper = a11yWrapper
  }

  private var windowScene: UIWindowScene? {
    window.windowScene
  }

  private let window: UIWindow
  private let a11yWrapper: ((UIViewController, UIWindow, PreviewLayout) -> UIView)?
  private var geometryUpdateError: Error?

  // The first preview rendered in a freshly-created window settles ~bottom-safe-area
  // shorter than every subsequent one: UIKit only keeps the bottom inset resolved for
  // a view grown taller than the window AFTER the window has already expanded one such
  // view through a full (asynchronous) layout settle. A static layout pass doesn't
  // reproduce it — only a real expansion does. Since the strategy (and its window) is
  // cached and reused across a subclass's whole preview set, whichever preview a
  // parallel test worker runs first captures wrong, making heights order-dependent.
  // Run one throwaway expansion of the first preview to establish that state, then
  // render it again for the captured result.
  private var hasWarmedUp = false

  @MainActor
  public func render(
      preview: SnapshotPreviewsCore.Preview,
      completion: @escaping (SnapshotResult) -> Void
  ) {
      Self.setup()
      if !hasWarmedUp {
          hasWarmedUp = true
          performRender(preview: preview) { [weak self] _ in
              // Discard the warm-up capture; render again now that the window's
              // safe-area state matches what every later preview will see.
              self?.render(preview: preview, completion: completion)
          }
          return
      }
      geometryUpdateError = nil
      let targetOrientation = preview.orientation.toInterfaceOrientation()
      guard #available(iOS 16.0, *), windowScene!.interfaceOrientation != targetOrientation else {
          performRender(preview: preview, completion: completion)
          return
      }
    
      windowScene!.requestGeometryUpdate(.iOS(interfaceOrientations: targetOrientation.toInterfaceOrientationMask())) { error in
          NSLog("Rotation error handler: \(error) \(self.windowScene!.interfaceOrientation)")
          DispatchQueue.main.async {
              self.geometryUpdateError = error
          }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
          self?.waitForOrientationChange(targetOrientation: targetOrientation, preview: preview, attempts: 50, completion: completion)
      }
  }

  @MainActor private func waitForOrientationChange(
      targetOrientation: UIInterfaceOrientation,
      preview: SnapshotPreviewsCore.Preview,
      attempts: Int,
      completion: @escaping (SnapshotResult) -> Void
  ) {
      if let geometryUpdateError {
        if (geometryUpdateError as NSError).userInfo["BSErrorCodeDescription"] as? String == "timeout" {
            completion(SnapshotResult(image: .failure(RenderingError.orientationChangeTimeout), precision: nil, accessibilityEnabled: nil, colorScheme: nil, appStoreSnapshot: nil))
            return
        }
        completion(SnapshotResult(image: .failure(geometryUpdateError), precision: nil, accessibilityEnabled: nil, colorScheme: nil, appStoreSnapshot: nil))
        return
      }
      guard attempts > 0 else {
          let timeoutError = NSError(domain: "OrientationChangeTimeout", code: 0, userInfo: [NSLocalizedDescriptionKey: "Orientation change timed out"])
        completion(SnapshotResult(image: .failure(timeoutError), precision: nil, accessibilityEnabled: nil, colorScheme: nil, appStoreSnapshot: nil))
          return
      }

      if windowScene!.interfaceOrientation == targetOrientation {
          performRender(preview: preview, completion: completion)
      } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
              self?.waitForOrientationChange(targetOrientation: targetOrientation, preview: preview, attempts: attempts - 1, completion: completion)
          }
      }
  }

  @MainActor private func performRender(
    preview: SnapshotPreviewsCore.Preview,
    completion: @escaping (SnapshotResult) -> Void
  ) {
    UIView.setAnimationsEnabled(false)
    let view = preview.view()
    let controller = view.makeExpandingView(layout: preview.layout, window: window)
    view.snapshot(
      layout: preview.layout,
      controller: controller,
      window: window,
      async: false,
      a11yWrapper: a11yWrapper) { result in
        completion(result)
      }
  }
}
#endif
