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

  /// The window is reused across a test class's whole preview set, so the rendered preview stays
  /// hosted (and alive) until the next render replaces it. Swap in an empty root now so a
  /// deallocation check can run before the next preview.
  @MainActor public func releaseRenderedPreview() {
    dismantleHostedPreview()
    window.rootViewController = UIViewController()
  }

  /// Gives the hosting controller one last SwiftUI update with nothing in it before it is
  /// discarded. SwiftUI on iOS 18 keeps a hosting view's graph, and everything the graph owns,
  /// alive until its next update; a controller that is simply dropped from the window never gets
  /// one, so without this the previewed screen looks retained long after the render.
  @MainActor private func dismantleHostedPreview() {
    guard let root = window.rootViewController, let expanding = Self.expandingViewController(under: root) else { return }
    // The render already reported; a second settle from this update must not fire the callback.
    expanding.expansionSettled = nil
    expanding.rootView = EmergeModifierView(wrapped: EmptyView())
    expanding.view.layoutIfNeeded()
  }

  private static func expandingViewController(under viewController: UIViewController) -> ExpandingViewController? {
    if let expanding = viewController as? ExpandingViewController {
      return expanding
    }
    for child in viewController.children {
      if let expanding = expandingViewController(under: child) {
        return expanding
      }
    }
    return nil
  }

  private let window: UIWindow
  private let a11yWrapper: ((UIViewController, UIWindow, PreviewLayout) -> UIView)?
  private var geometryUpdateError: Error?

  // The first over-tall view captured in a freshly-created window settles
  // ~bottom-safe-area shorter than every subsequent one: UIKit only keeps the bottom
  // inset resolved for a view grown taller than the window AFTER the window has already
  // expanded *and captured* one such view (the collapse happens in the accessibility
  // capture path, so a non-a11y or expansion-only warm-up doesn't reproduce it). The
  // strategy (and its window) is cached and reused across a subclass's whole preview
  // set, so that anomaly otherwise lands on whichever preview renders first, making
  // heights order-dependent. We pre-empt it with one throwaway warm-up render before
  // the first real capture in each orientation:
  //   - A dedicated, guaranteed-over-tall dummy (not the first real preview, which may
  //     be short and never expand — leaving the state unestablished for later previews),
  //     rendered through the strategy's own `a11yWrapper` so it exercises the path that
  //     actually collapses.
  //   - Warmed lazily per interface orientation, *after* orientation settles, so a
  //     rotated-first preview is captured in an already-warmed orientation.
  //
  // No locking/queue is needed: callers drive rendering serially — `SnapshotTest`
  // awaits each render's completion (`wait(for:)`) before the next, and parallel
  // testing runs in separate processes — so `render` is never re-entered before its
  // completion fires, even though a render has async suspension points internally.
  private var warmedOrientations: Set<UIInterfaceOrientation> = []

  @MainActor
  public func render(
      preview: SnapshotPreviewsCore.Preview,
      completion: @escaping (SnapshotResult) -> Void
  ) {
      Self.setup()
      geometryUpdateError = nil
      let targetOrientation = preview.orientation.toInterfaceOrientation()
      guard #available(iOS 16.0, *), windowScene!.interfaceOrientation != targetOrientation else {
          warmThenRender(preview: preview, completion: completion)
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
          warmThenRender(preview: preview, completion: completion)
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
    dismantleHostedPreview()
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

  // Ensures the current interface orientation has been warmed (see `warmedOrientations`)
  // before capturing. Callers reach here only once orientation has settled, so the
  // warm-up runs in the orientation the capture will use.
  @MainActor private func warmThenRender(
    preview: SnapshotPreviewsCore.Preview,
    completion: @escaping (SnapshotResult) -> Void
  ) {
    let orientation = windowScene?.interfaceOrientation ?? .portrait
    // The collapse only occurs in the accessibility capture path, so only a11y
    // strategies need warming. A plain `SnapshotTest` strategy (nil `a11yWrapper`)
    // would gain nothing from a warm-up — just an extra render against the caller's
    // per-render timeout — so skip it there.
    guard a11yWrapper != nil, !warmedOrientations.contains(orientation) else {
      performRender(preview: preview, completion: completion)
      return
    }
    // Warm this orientation, then render once it settles. Safe to defer the render to
    // the warm-up's completion because rendering is serial (see `warmedOrientations`):
    // no other render will start in the meantime.
    warmUp { [weak self] in
      guard let self else { return }
      self.warmedOrientations.insert(orientation)
      self.performRender(preview: preview, completion: completion)
    }
  }

  // Throwaway render of a view guaranteed taller than the window, to establish the
  // window's safe-area state before the first real capture. Crucially it renders
  // through the strategy's own `a11yWrapper`: the safe-area collapse this warms past
  // happens in the accessibility capture path (AccessibilitySnapshotView), so warming
  // without that wrapper leaves a11y previews at the collapsed height.
  @MainActor private func warmUp(completion: @escaping () -> Void) {
    let dummy = WarmUpScrollView(contentHeight: max(window.bounds.height, 1) * 2)
    let controller = dummy.makeExpandingView(layout: .device, window: window)
    dummy.snapshot(
      layout: .device,
      controller: controller,
      window: window,
      async: false,
      a11yWrapper: a11yWrapper) { _ in
        completion()
      }
  }
}

// A scroll view whose content is taller than its frame, used only to warm up the
// render window (see `UIKitRenderingStrategy.warmUp`). Mirrors the `.always` content
// inset of typical UIKit-hosted previews so the warm-up reproduces the first-expansion
// safe-area collapse it exists to pre-empt.
private struct WarmUpScrollView: UIViewRepresentable {
  let contentHeight: CGFloat

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.contentInsetAdjustmentBehavior = .always
    let content = UIView()
    content.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      content.heightAnchor.constraint(equalToConstant: contentHeight),
    ])
    return scrollView
  }

  func updateUIView(_ uiView: UIScrollView, context: Context) {}
}
#endif
