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
  // Asks the host to schedule another layout pass. UIKit hosts implement
  // this as view.setNeedsLayout(); AppKit / unsupported platforms can no-op.
  func setNeedsAnotherLayoutPass()
}

extension ScrollExpansionProviding {
  func setNeedsAnotherLayoutPass() {}

  func updateHeight(_ complete: (() -> Void)) {
    // Cap on contentSize-not-stabilized retries before we give up and complete
    // anyway. Prevents an infinite wait on a genuinely empty / animating view.
    let maxPendingContentSizeRetries = 10
    // If heightAnchor isn't set, this was a fixed size and we don't expand the scroll view
    guard let heightAnchor else {
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
              complete()
              return
            }
          }
          previousHeight = scrollView.visibleContentHeight
          heightAnchor.constant += CGFloat(diff)
        } else {
          complete()
        }
      } else {
        complete()
      }
    } else {
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
