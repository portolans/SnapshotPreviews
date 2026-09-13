//
//  View+Snapshot.swift
//  FindPreviews
//
//  Created by Noah Martin on 12/22/22.
//

import CoreFoundation

public enum RenderingError: Error {
  case failedRendering(CGSize)
  case maxSize(CGSize)
  case expandingViewTimeout(CGSize)
  case orientationChangeTimeout
}

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import Foundation
import SwiftUI
import UIKit
import SnapshotSharedModels

private var _colorScheme: ColorScheme? = nil

extension View {
  public func makeExpandingView(layout: PreviewLayout, window: UIWindow) -> ExpandingViewController {
    UIView.setAnimationsEnabled(false)
    var wrappedView: any View = self.transaction { transaction in
      transaction.disablesAnimations = true
    }
    _colorScheme = nil
    wrappedView = PreferredColorSchemeWrapper {
      AnyView(wrappedView)
    } colorSchemeUpdater: { scheme in
      _colorScheme = scheme
    }
    let controller = ExpandingViewController(rootView: wrappedView)
    PreviewDeallocationTracker.trackHost(controller)
    controller.setupView(layout: layout)

    let windowRootVC = Self.setupRootVC(subVC: controller)
    window.rootViewController = windowRootVC
    // Drain layout passes triggered by safe-area propagation. The first call
    // propagates window safeAreaInsets to descendants, firing safeAreaInsetsDidChange;
    // consumer view-controller overrides typically call setNeedsLayout in response,
    // so a second call is needed to flush that cascade before the settle loop
    // measures intrinsicContentSize.
    windowRootVC.view.layoutIfNeeded()
    windowRootVC.view.layoutIfNeeded()
    return controller
  }

  public func snapshot(
    layout: PreviewLayout,
    controller: ExpandingViewController,
    window: UIWindow,
    async: Bool,
    a11yWrapper: ((UIViewController, UIWindow, PreviewLayout) -> UIView)? = nil,
    completion: @escaping (SnapshotResult) -> Void)
  {
    controller.expansionSettled = { [weak controller, weak window] renderingMode, precision, accessibilityEnabled, appStoreSnapshot, error in
      guard let controller, let window, let containerVC = controller.parent else {
        return
      }

      if let error {
        DispatchQueue.main.async {
          completion(SnapshotResult(image: .failure(error), precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot))
        }
        return
      }

      if async {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
          let imageResult = Self.takeSnapshot(layout: layout, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: controller.view)
          completion(SnapshotResult(image: imageResult.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot))
        }
      } else {
        DispatchQueue.main.async {
          // When a class-level a11yWrapper is provided we treat it as opt-in for every preview unless that preview explicitly disabled accessibility.
          // This lets test bundles run a single a11y-overlaying SnapshotTest subclass over their full preview set without per-#Preview annotations.
          if let a11yWrapper, accessibilityEnabled != false {
            // Dismiss first responder on the window BEFORE the a11y wrapper is
            // constructed. Wrappers like AccessibilitySnapshotView typically
            // capture the inner view as a static image at construction time
            // (via drawHierarchy / snapshotView) — by the time our render-site
            // endEditing in UIView.render fires on the wrapper, the inner
            // image with its blinking caret is already baked in. Firing here
            // catches the inner first responder before the snapshot is baked.
            window.endEditing(true)
            // The cursor subtree outlives the resign by a run-loop turn (see
            // `hideResidualTextCursorViews`), and this wrapper bakes the inner view to a
            // static image on construction, so anything still attached is baked in too.
            window.hideResidualTextCursorViews()
            let a11yView = a11yWrapper(controller, window, layout)
            let result = Self.takeSnapshot(layout: .sizeThatFits, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: a11yView)
            a11yView.removeFromSuperview()
            completion(SnapshotResult(image: result.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot))
          } else {
            let imageResult = Self.takeSnapshot(layout: layout, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: controller.view)
            completion(SnapshotResult(image: imageResult.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot))
          }
        }
      }
    }
  }

  private static func setupRootVC(subVC: UIViewController) -> UIViewController {
    let windowRootVC = UIViewController()
    windowRootVC.view.bounds = UIScreen.main.bounds
    windowRootVC.view.backgroundColor = .clear

    let containerVC = UIViewController()
    containerVC.view.backgroundColor = .clear
    containerVC.view.translatesAutoresizingMaskIntoConstraints = false
    windowRootVC.view.addSubview(containerVC.view)
    windowRootVC.addChild(containerVC)
    containerVC.didMove(toParent: windowRootVC)
    containerVC.view.widthAnchor.constraint(equalToConstant: UIScreen.main.bounds.width).isActive = true
    containerVC.view.heightAnchor.constraint(greaterThanOrEqualToConstant: UIScreen.main.bounds.height).isActive = true
    containerVC.view.centerXAnchor.constraint(equalTo: windowRootVC.view.centerXAnchor).isActive = true
    containerVC.view.centerYAnchor.constraint(equalTo: windowRootVC.view.centerYAnchor).isActive = true

    containerVC.view.addSubview(subVC.view)
    containerVC.addChild(subVC)
    subVC.didMove(toParent: containerVC)

    subVC.view.centerXAnchor.constraint(equalTo: containerVC.view.centerXAnchor).isActive = true
    subVC.view.centerYAnchor.constraint(equalTo: containerVC.view.centerYAnchor).isActive = true
    subVC.view.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width).isActive = true
    containerVC.view.heightAnchor.constraint(greaterThanOrEqualTo: subVC.view.heightAnchor, multiplier: 1).isActive = true

    return windowRootVC
  }

  private static func takeSnapshot(
    layout: PreviewLayout,
    renderingMode: EmergeRenderingMode?,
    window: UIWindow,
    rootVC: UIViewController,
    targetView: UIView,
    maxSize: Double = 1_000_000) -> Result<UIImage, RenderingError>
  {
    if renderingMode == EmergeRenderingMode.window {
      let format = UIGraphicsImageRendererFormat()
      format.scale = SnapshotRenderScale.value(defaultScale: window.screen.scale)
      let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
      let screenshot = renderer.image { _ in
        // iOS draws a blinking caret in any first-responder text input. Captures
        // taken at different points along the blink cycle produce flaky pixel
        // diffs in keyboard-bearing previews. endEditing(true) walks the view
        // hierarchy synchronously and dismisses the caret so each snapshot
        // renders deterministically. Fire immediately before render so view
        // controllers that re-acquire focus during view setup (e.g. via
        // viewWillAppear/viewDidAppear) don't re-claim focus before the pixel
        // capture happens.
        window.endEditing(true)
        window.hideResidualTextCursorViews()
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      return .success(screenshot)
    }

    let view = targetView
    let drawCode: (CGContext) -> Void

    CATransaction.commit()

    let targetSize: CGSize
    var success = false
    switch layout {
    case .fixed(width: let width, height: let height):
      targetSize = CGSize(width: width, height: height)
      drawCode = { ctx in
        success = view.render(size: targetSize, mode: renderingMode, context: ctx)
      }
    case .sizeThatFits:
      targetSize = view.bounds.size
      drawCode = { ctx in
        success = view.render(size: targetSize, mode: renderingMode, context: ctx)
      }
    case .device:
      fallthrough
    default:
      let viewSize = view.bounds.size

      targetSize = CGSize(width: UIScreen.main.bounds.size.width, height: max(viewSize.height, UIScreen.main.bounds.size.height))
      drawCode = { ctx in
        success = rootVC.view.render(size: targetSize, mode: renderingMode, context: ctx)
      }
    }
    if targetSize.height > maxSize || targetSize.width > maxSize {
      return .failure(RenderingError.maxSize(targetSize))
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = SnapshotRenderScale.value(defaultScale: window.screen.scale)
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let image = renderer.image { context in
      drawCode(context.cgContext)
    }
    if !success {
      return .failure(RenderingError.failedRendering(targetSize))
    }
    return .success(image)
  }
}

extension CGSize {
  var requiresCoreAnimationSnapshot: Bool {
    height >= UIScreen.main.bounds.size.height * 2
  }
}

extension UIView {
  func render(size: CGSize, mode: EmergeRenderingMode?, context: CGContext) -> Bool {
    // iOS draws a blinking caret in any first-responder text input. Captures
    // taken at different points along the blink cycle produce flaky pixel
    // diffs in keyboard-bearing previews. endEditing(true) walks the view
    // hierarchy synchronously and dismisses the caret so each snapshot
    // renders deterministically. Fire immediately before render so view
    // controllers that re-acquire focus during view setup (e.g. via
    // viewWillAppear/viewDidAppear) don't re-claim focus before the pixel
    // capture happens.
    //
    // Escalate to the host window when available: a11y wrappers
    // (`AccessibilitySnapshotView`) render the inner content into a separate
    // sibling view that's not in `self`'s subtree, so endEditing on `self`
    // alone misses the inner first responder. Calling endEditing on the
    // window covers the whole hierarchy.
    let editingRoot = window ?? self
    editingRoot.endEditing(true)
    // ...but resigning is only half of it: UIKit removes the cursor subtree on a later
    // turn of the run loop, so a capture taken immediately after `endEditing` can still
    // find it attached and draw it. Measured on iOS 18.0: first responder is already nil
    // while `_UITextCursorTrailingGlowView` (alpha 0.32) and `_UICursorAccessoryView` are
    // still visible in the tree, carrying no animations — a static leftover, not a blink
    // phase. Whether that teardown wins the race against the capture is what made these
    // snapshots flake. Hide what survives instead of waiting for it to go, so the result
    // does not depend on timing. Spinning the run loop here would also let unrelated
    // deferred work run, which is exactly the nondeterminism this harness exists to avoid.
    editingRoot.hideResidualTextCursorViews()
    switch mode {
    case .coreAnimation:
      layer.layerForSnapshot.render(in: context)
      return true
    case .uiView:
      return drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
    case .window, .none:
      if !size.requiresCoreAnimationSnapshot {
        return drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
      } else {
        layer.layerForSnapshot.render(in: context)
        return true
      }
    }
  }
}

extension CALayer {

  var layerForSnapshot: Self {
    guard !hasMapView else {
      return self
    }

    return presentation() ?? self
  }

  var hasMapView: Bool {
    if type(of: self).description() == "VKMapView" {
      return true
    }
    for s in sublayers ?? [] {
      if s.hasMapView {
        return true
      }
    }
    return false
  }
}


extension UIView {
  /// Hides any text-cursor decoration left attached after `endEditing(true)`.
  ///
  /// The four decorations observed on iOS 18.0 are `UIStandardTextCursorView`,
  /// `_UITextCursorTrailingGlowView`, `_UICursorAccessoryHostView` and
  /// `_UICursorAccessoryView`. Matching the `Cursor`/`Caret` stem rather than those exact
  /// names keeps a renamed or newly added decoration covered, since missing one is a
  /// benign regression to the previous behaviour.
  ///
  /// The UIKit-prefix requirement is what keeps that breadth safe: hiding a real view
  /// would silently drop content from a baseline, which is far worse than missing a
  /// caret, and a consumer's own `MapCursorView` or `DisclosureCaretView` matches the
  /// stem while carrying no `UI` prefix.
  ///
  /// The mutation is committed rather than left to the ambient implicit transaction:
  /// `layerForSnapshot` renders `presentation()`, and an uncommitted model-layer change
  /// is not in the presentation tree yet — so the caret would survive in exactly the
  /// `.coreAnimation` and over-tall paths this is meant to fix. Committing a transaction
  /// whose actions are disabled publishes the change without running unrelated work, so
  /// it does not reintroduce the nondeterminism that rules out spinning the run loop.
  func hideResidualTextCursorViews() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hideMatchingCursorViews()
    CATransaction.commit()
  }

  private func hideMatchingCursorViews() {
    // Generic arguments are dropped before matching: `String(describing:)` spells a generic
    // view as `_UIHostingView<SomeContent>`, so a consumer type named for a cursor would
    // otherwise supply the stem while the UIKit wrapper supplies the prefix — hiding a whole
    // hosting view of real content. The decorations below are plain ObjC classes, so their
    // base name is the whole name.
    let baseName = String(describing: type(of: self)).prefix { $0 != "<" }
    let isUIKitInternal = baseName.hasPrefix("UI") || baseName.hasPrefix("_UI")
    if isUIKitInternal, baseName.contains("Cursor") || baseName.contains("Caret") {
      isHidden = true
    }
    for subview in subviews {
      subview.hideMatchingCursorViews()
    }
  }
}

#endif
