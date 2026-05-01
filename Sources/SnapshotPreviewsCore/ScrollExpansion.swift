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
  // scroll view's contentSize to be populated. iOS 18 reordered hosting
  // controller layout passes so the inner UIKit layout (where contentSize
  // is assigned) can lag the outer viewDidLayoutSubviews — without this
  // counter we'd race into complete() at one screen-height.
  var pendingContentSizeRetries: Int { get set }
  // Asks the host to schedule another layout pass. UIKit hosts implement
  // this as view.setNeedsLayout(); AppKit / unsupported platforms can no-op.
  func setNeedsAnotherLayoutPass()
}

extension ScrollExpansionProviding {
  func setNeedsAnotherLayoutPass() {}

  func updateHeight(_ complete: (() -> Void)) {
    // Cap on contentSize-not-laid-out retries before we give up and complete
    // anyway. Prevents an infinite wait on a genuinely empty scroll view.
    let maxPendingContentSizeRetries = 10
    // If heightAnchor isn't set, this was a fixed size and we don't expand the scroll view
    guard let heightAnchor else {
      complete()
      return
    }

    let supportsExpansion = supportsExpansion
    let scrollView = firstScrollView
    if let scrollView, supportsExpansion {
      // Layout-pass race: on the first viewDidLayoutSubviews the inner
      // scroll view may not have laid out yet, so contentHeight is 0 and
      // diff is -visibleHeight. Without this guard we'd take the else
      // branch below and complete() at one screen-height. Defer until we
      // actually see a contentSize, capped at maxPendingContentSizeRetries
      // so a truly empty scroll view eventually completes.
      if previousHeight == nil,
         scrollView.contentHeight == 0,
         pendingContentSizeRetries < maxPendingContentSizeRetries {
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
