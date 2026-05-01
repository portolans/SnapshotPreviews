//
//  ScrollExpansion.swift
//
//
//  Created by Noah Martin on 8/22/24.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

protocol ContentHeightProviding {
  var contentHeight: CGFloat { get }

  var visibleContentHeight: CGFloat { get }
}

// Cross-platform CGSize formatter for [snapshot-debug] log lines. UIKit's
// NSStringFromCGSize isn't available on all targets compiled by this file,
// so we format manually for consistency.
func snapshotDebugString(_ size: CGSize) -> String {
  "{\(size.width), \(size.height)}"
}

protocol FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? { get }
}

#if !os(watchOS)
protocol ScrollExpansionProviding: AnyObject, FirstScrollViewProviding {
  var previousHeight: CGFloat? { get set }
  var heightAnchor: NSLayoutConstraint? { get }
  var supportsExpansion: Bool { get }
  // Tracks how many times we've deferred completion waiting for the inner
  // scroll view's contentSize to stabilize. iOS 18 reordered hosting
  // controller layout passes so the inner UIKit layout (where contentSize
  // is assigned) can lag — and may land at a partial value before the
  // final one — without this counter we'd race into complete() at the
  // wrong height.
  var pendingContentSizeRetries: Int { get set }
  // Last contentSize observation. Used to detect stabilization: we only
  // commit when two consecutive passes report the same height.
  var lastObservedContentHeight: CGFloat? { get set }
  // Tracks how many times we've deferred completion waiting for the host's
  // intrinsic-content-size / fitting size to stabilize on the non-scroll
  // path. Same iOS 18 hosting-controller pass-reordering issue as the scroll
  // counter, but for views that don't have an inner UIScrollView (e.g. a
  // hosting controller wrapping a fixed-layout SwiftUI view).
  var pendingIntrinsicSizeRetries: Int { get set }
  // Last intrinsic-size observation. Used to detect stabilization: we only
  // commit when two consecutive passes report the same fitting size.
  var lastObservedIntrinsicSize: CGSize? { get set }
  // The host's currently-resolved fitting size. Implementations return
  // `view.systemLayoutSizeFitting(...)` (UIKit) or
  // `view.fittingSize` (AppKit). Returning nil signals "no useful intrinsic
  // size to wait on" — settle loop falls through to immediate completion.
  var hostFittingSize: CGSize? { get }
  // Asks the host to schedule another layout pass. UIKit hosts implement
  // this as view.setNeedsLayout(); AppKit / unsupported platforms can no-op.
  func setNeedsAnotherLayoutPass()
}

extension ScrollExpansionProviding {
  func setNeedsAnotherLayoutPass() {}

  var hostFittingSize: CGSize? { nil }

  func updateHeight(_ complete: (() -> Void)) {
    // Cap on contentSize-not-stabilized retries before we give up and complete
    // anyway. Prevents an infinite wait on a genuinely empty / animating view.
    let maxPendingContentSizeRetries = 10
    // Symmetric cap for the intrinsic-size settle loop.
    let maxPendingIntrinsicSizeRetries = 10
    let objectID = UInt(bitPattern: ObjectIdentifier(self).hashValue)
    // If heightAnchor isn't set, this was a fixed size and we don't expand the scroll view
    guard let heightAnchor else {
      NSLog("[snapshot-debug] event=settle-complete path=none id=%lx reason=no-heightAnchor", objectID)
      complete()
      return
    }

    let supportsExpansion = supportsExpansion
    let scrollView = firstScrollView
    if let scrollView, supportsExpansion {
      // Stabilization: scroll content can land at a partial height before its
      // final size when SwiftUI hosting / UIKit child layout completes in
      // multiple passes. We retry until we see the same non-zero contentHeight
      // on two consecutive passes — a stable observation — before committing.
      // Without this, we capture at intermediate layout states and produce
      // run-to-run dimension drift on iOS 18 / Apple Silicon.
      let currentContentHeight = scrollView.contentHeight
      NSLog("[snapshot-debug] event=settle path=scroll id=%lx pass=%d contentHeight=%g lastObserved=%@",
            objectID, pendingContentSizeRetries, currentContentHeight,
            lastObservedContentHeight.map { String(describing: $0) } ?? "nil")
      guard previousHeight != nil
              || (currentContentHeight > 0 && lastObservedContentHeight == currentContentHeight)
              || pendingContentSizeRetries >= maxPendingContentSizeRetries else {
        lastObservedContentHeight = currentContentHeight
        pendingContentSizeRetries += 1
        setNeedsAnotherLayoutPass()
        return
      }
      let diff = Int(scrollView.contentHeight - scrollView.visibleContentHeight)
      if abs(diff) > 0 {
        if previousHeight != nil || diff > 0 {
          if let previousHeight {
            // Check if expansion isn't working and we should give up.
            // Could happen if the view is constrained to not grow, such as a half sheet
            guard abs(previousHeight - scrollView.visibleContentHeight) >= 1 else {
              NSLog("[snapshot-debug] event=settle-complete path=scroll id=%lx pass=%d contentHeight=%g reason=no-expansion retriesCapped=%d",
                    objectID, pendingContentSizeRetries, currentContentHeight,
                    pendingContentSizeRetries >= maxPendingContentSizeRetries ? 1 : 0)
              complete()
              return
            }
          }
          previousHeight = scrollView.visibleContentHeight
          heightAnchor.constant += CGFloat(diff)
        } else {
          NSLog("[snapshot-debug] event=settle-complete path=scroll id=%lx pass=%d contentHeight=%g reason=negative-diff retriesCapped=%d",
                objectID, pendingContentSizeRetries, currentContentHeight,
                pendingContentSizeRetries >= maxPendingContentSizeRetries ? 1 : 0)
          complete()
        }
      } else {
        NSLog("[snapshot-debug] event=settle-complete path=scroll id=%lx pass=%d contentHeight=%g reason=zero-diff retriesCapped=%d",
              objectID, pendingContentSizeRetries, currentContentHeight,
              pendingContentSizeRetries >= maxPendingContentSizeRetries ? 1 : 0)
        complete()
      }
    } else {
      // Non-scroll path. UIHostingController's two-pass layout can also drop
      // intrinsic content size into the host view *after* the first
      // viewDidLayoutSubviews — same race as the scroll-view path, but
      // observed via systemLayoutSizeFitting / fittingSize instead of
      // contentSize. Wait until two consecutive passes report the same
      // fitting size before committing.
      guard let fittingSize = hostFittingSize,
            fittingSize.width > 0 || fittingSize.height > 0 else {
        // Either the host doesn't expose a fitting size, or it returned
        // (noIntrinsicMetric, noIntrinsicMetric)-equivalent zeros — there's
        // nothing meaningful to wait on, complete immediately.
        NSLog("[snapshot-debug] event=settle-complete path=intrinsic id=%lx reason=no-fitting-size",
              objectID)
        complete()
        return
      }
      NSLog("[snapshot-debug] event=settle path=intrinsic id=%lx pass=%d fitting=%@ lastObserved=%@",
            objectID, pendingIntrinsicSizeRetries, snapshotDebugString(fittingSize),
            lastObservedIntrinsicSize.map { snapshotDebugString($0) } ?? "nil")
      guard lastObservedIntrinsicSize == fittingSize
              || pendingIntrinsicSizeRetries >= maxPendingIntrinsicSizeRetries else {
        lastObservedIntrinsicSize = fittingSize
        pendingIntrinsicSizeRetries += 1
        setNeedsAnotherLayoutPass()
        return
      }
      NSLog("[snapshot-debug] event=settle-complete path=intrinsic id=%lx pass=%d fitting=%@ retriesCapped=%d",
            objectID, pendingIntrinsicSizeRetries,
            snapshotDebugString(fittingSize),
            pendingIntrinsicSizeRetries >= maxPendingIntrinsicSizeRetries ? 1 : 0)
      complete()
    }
  }
}
#endif

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
extension UIScrollView: ContentHeightProviding {

  var contentHeight: CGFloat {
    contentSize.height
  }

  var visibleContentHeight: CGFloat {
    frame.height - (adjustedContentInset.top + adjustedContentInset.bottom)
  }
}

extension UIView: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    var subviews = subviews
    while !subviews.isEmpty {
      let subview = subviews.removeFirst()
      // Don’t expand UITextView, it can cause flakes
      guard !(subview is UITextView) else {
        continue
      }

      subviews.append(contentsOf: subview.subviews)
      if let scrollView = subview as? UIScrollView {
        return scrollView
      }
    }
    return nil
  }
}

extension UIViewController: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    view?.firstScrollView
  }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension NSScrollView: ContentHeightProviding {

  var contentHeight: CGFloat {
    documentView?.frame.size.height ?? 0
  }

  var visibleContentHeight: CGFloat {
    frame.height - (contentInsets.top + contentInsets.bottom)
  }
}

extension NSView: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    var subviews = subviews
    while !subviews.isEmpty {
      let subview = subviews.removeFirst()
      if let scrollView = subview as? NSScrollView {
        // Don’t expand NSTextView, it can cause flakes
        guard !(scrollView.documentView is NSTextView) else {
          continue
        }

        return scrollView
      }
      subviews.append(contentsOf: subview.subviews)
    }
    return nil
  }
}

extension NSViewController: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    view.firstScrollView
  }
}
#endif
