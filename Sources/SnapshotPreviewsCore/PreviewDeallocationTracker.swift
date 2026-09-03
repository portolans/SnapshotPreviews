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
    fileprivate var host: WeakViewController?
    fileprivate var released = false

    /// Whether the strategy has discarded this preview's render. Until it has, the controllers are
    /// legitimately hosted and say nothing about the screen; a render that failed before
    /// replacing the window's root leaves the previous preview in place.
    public var wasReleased: Bool {
      released
    }

    /// The tracked view controllers that are still alive.
    public var survivingViewControllers: [UIViewController] {
      controllers.compactMap(\.viewController)
    }

    /// Where each surviving controller still sits, for a failure report: its parent, its view's
    /// superview, and whether that view is still in a window. The harness's own hosting
    /// controller is described the same way when it is still alive.
    public var survivorPlacement: String {
      var placements = survivingViewControllers.map(Self.placement(of:))
      if let host = host?.viewController {
        placements.append("host " + Self.placement(of: host) + ", children=\(host.children.map { String(describing: type(of: $0)) })")
      }
      return placements.joined(separator: "; ")
    }

    private static func placement(of viewController: UIViewController) -> String {
      let parent = viewController.parent.map { String(describing: type(of: $0)) } ?? "nil"
      let superview = viewController.viewIfLoaded?.superview.map { String(describing: type(of: $0)) } ?? "nil"
      let inWindow = viewController.viewIfLoaded?.window != nil
      return "\(type(of: viewController)): parent=\(parent), superview=\(superview), inWindow=\(inWindow)"
    }

    /// Whether the harness's own hosting controller for this preview is still alive. A leaked
    /// screen can keep it alive, so this is diagnostic context for a report, not a verdict.
    public var hostIsAlive: Bool {
      host?.viewController != nil
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

  /// Previews whose controllers were still alive one render later. Judged once at the end of the
  /// class, after a single bounded wait, rather than by waiting inside a test: under parallel
  /// testing, waiting on the main run loop from inside a test method has hung the test host.
  public static var deferredPreviews: [RenderedPreview] {
    deferred
  }

  /// Sets a preview aside to be judged at the end of the class.
  public static func deferJudgement(of preview: RenderedPreview) {
    deferred.append(preview)
  }

  /// Records that the strategy has discarded the render hosted by `host`, so the preview it
  /// belongs to can be judged.
  public static func hostDismantled(_ host: UIViewController) {
    if current?.host?.viewController === host { current?.released = true }
    if previous?.host?.viewController === host { previous?.released = true }
    for index in deferred.indices where deferred[index].host?.viewController === host {
      deferred[index].released = true
    }
  }

  /// Forgets every tracked preview. Each test class starts and ends with a clean slate so one
  /// class's last render, still hosted in that class's own window, is never judged by the next.
  public static func reset() {
    current = nil
    previous = nil
    deferred = []
  }

  static func track(_ viewController: UIViewController) {
    current?.controllers.append(WeakViewController(viewController))
  }

  static func trackHost(_ viewController: UIViewController) {
    // A new host means a new render of this preview; whatever the strategy discarded before it
    // (the accessibility warm-up's throwaway host, say) says nothing about this render.
    current?.host = WeakViewController(viewController)
    current?.released = false
  }

  fileprivate struct WeakViewController {
    init(_ viewController: UIViewController) {
      self.viewController = viewController
    }

    weak var viewController: UIViewController?
  }

  private static var current: RenderedPreview?
  private static var previous: RenderedPreview?
  private static var deferred: [RenderedPreview] = []
}
#endif
