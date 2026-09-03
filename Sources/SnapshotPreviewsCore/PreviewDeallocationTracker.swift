//
//  PreviewDeallocationTracker.swift
//
//
//  Created by Dan Federman on 9/3/26.
//

#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// Remembers every `UIViewController` a preview built during a render so a test can check, after the
/// preview has been torn down, that none of them is still alive.
///
/// A view controller that survives its own teardown is retaining itself: a stored closure that
/// captured `self`, a child holding its parent, a subscription without a weak observer. In an app
/// that same cycle keeps a screen and everything it references alive after the user navigates away
/// or logs out. Previews build each screen from its real object graph, so checking here catches the
/// cycle on the PR that introduces it.
@MainActor
public enum PreviewDeallocationTracker {
  /// Forgets the view controllers tracked for the previous preview. Call before rendering.
  public static func reset() {
    tracked.removeAll()
  }

  /// The tracked view controllers that are still alive. Call after the rendered preview has been
  /// released and the run loop has had a chance to drain.
  public static func survivingViewControllers() -> [UIViewController] {
    tracked.compactMap(\.viewController)
  }

  static func track(_ viewController: UIViewController) {
    tracked.append(WeakViewController(viewController))
  }

  private struct WeakViewController {
    init(_ viewController: UIViewController) {
      self.viewController = viewController
    }

    weak var viewController: UIViewController?
  }

  private static var tracked: [WeakViewController] = []
}
#endif
