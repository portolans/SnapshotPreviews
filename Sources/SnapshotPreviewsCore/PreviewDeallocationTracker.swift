//
//  PreviewDeallocationTracker.swift
//
//
//  Created by Dan Federman on 9/3/26.
//

#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// Remembers every `UIViewController` a preview built during its render so a test can check, once
/// the preview has been replaced by the next one, that none of them is still alive.
///
/// A view controller that survives its own teardown is retaining itself: a stored closure that
/// captured `self`, a child holding its parent, a subscription without a weak observer. In an app
/// that same cycle keeps a screen and everything it references alive after the user navigates away
/// or logs out. Previews build each screen from its real object graph, so checking here catches the
/// cycle on the PR that introduces it.
///
/// The check is deferred by one preview on purpose. UIKit lets go of an unhosted view controller
/// over several run-loop turns (more than a second on iOS 18), so checking right after teardown
/// would either report latency as a leak or wait on every preview. By the time the next preview has
/// rendered, a healthy controller from the previous one is long gone, and the wait costs nothing.
@MainActor
public enum PreviewDeallocationTracker {
  /// A rendered preview and the view controllers it built.
  public struct RenderedPreview {
    /// The name the test reports the preview under.
    public let name: String
    /// The `#Preview`'s file, as `PreviewType.fileID` reports it.
    public let fileID: String?
    /// The `#Preview`'s line.
    public let line: Int?

    fileprivate var controllers: [WeakViewController] = []

    /// The tracked view controllers that are still alive.
    public var survivingViewControllers: [UIViewController] {
      controllers.compactMap(\.viewController)
    }
  }

  /// Starts tracking the preview about to render. Call before each render.
  public static func beginPreview(name: String, fileID: String?, line: Int?) {
    previous = current
    current = RenderedPreview(name: name, fileID: fileID, line: line)
  }

  /// The preview rendered before the current one. Its controllers were released when the current
  /// preview replaced it in the window, so any that survive are retained by their own graph.
  public static var previousPreview: RenderedPreview? {
    previous
  }

  /// The most recently rendered preview. Nothing has replaced it yet, so judge it only after the
  /// strategy has released it and the run loop has had time to let it go.
  public static var currentPreview: RenderedPreview? {
    current
  }

  static func track(_ viewController: UIViewController) {
    current?.controllers.append(WeakViewController(viewController))
  }

  fileprivate struct WeakViewController {
    init(_ viewController: UIViewController) {
      self.viewController = viewController
    }

    weak var viewController: UIViewController?
  }

  private static var current: RenderedPreview?
  private static var previous: RenderedPreview?
}
#endif
