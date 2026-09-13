#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import UIKit
import XCTest
@testable import SnapshotPreviewsCore

/// Covers the direction snapshot fixtures cannot: that a consumer's own view is left alone.
///
/// A fixture proves a caret disappears by producing a clean render. Nothing proves the
/// converse, because a view wrongly hidden also produces a clean render — one silently
/// missing its content. These assertions are the only thing standing between this matcher
/// and a corrupted baseline, so each one encodes a way the predicate has actually been
/// wrong in review rather than a hypothetical.
final class TextCursorHidingTests: XCTestCase {
  /// A consumer type may be named anything, including UIKit's convention. Review of #17
  /// raised exactly this spelling: the `UI` prefix is a convention, not proof of ownership.
  func testConsumerViewNamedLikeUIKitIsNotHidden() {
    let view = UICursorLegendView()
    UIView().withSubview(view).hideResidualTextCursorViews()
    XCTAssertFalse(view.isHidden)
  }

  /// A consumer type reaching the matcher through a generic argument on a genuinely
  /// UIKit-owned wrapper — the shape that defeated the prefix check.
  func testConsumerViewInsideGenericNameIsNotHidden() {
    let view = CursorBox<CaretContent>()
    UIView().withSubview(view).hideResidualTextCursorViews()
    XCTAssertFalse(view.isHidden)
  }

  /// The stem alone must not be sufficient; ownership is the deciding condition.
  func testUnrelatedConsumerViewIsNotHidden() {
    let view = MapCursorView()
    UIView().withSubview(view).hideResidualTextCursorViews()
    XCTAssertFalse(view.isHidden)
  }

  /// Hiding is recursive, so a consumer view nested below one is equally at risk.
  func testNestedConsumerViewIsNotHidden() {
    let nested = UICursorLegendView()
    let parent = UIView().withSubview(UIView().withSubview(nested))
    parent.hideResidualTextCursorViews()
    XCTAssertFalse(nested.isHidden)
  }

  /// Guards the ownership check itself: if `Bundle(for:)` ever stopped distinguishing the
  /// two, every assertion above would pass for the wrong reason.
  func testTestBundleIsNotTheUIKitBundle() {
    XCTAssertNotEqual(Bundle(for: UICursorLegendView.self), Bundle(for: UIView.self))
  }
}

// MARK: - Fixtures

/// Named to match UIKit's convention on purpose.
private final class UICursorLegendView: UIView {}

private final class MapCursorView: UIView {}

private final class CursorBox<Content>: UIView {}

private enum CaretContent {}

extension UIView {
  fileprivate func withSubview(_ subview: UIView) -> UIView {
    addSubview(subview)
    return self
  }
}
#endif
