//
//  ExpandingViewController.swift
//  TestAppSwiftUI
//
//  Created by Noah Martin on 6/30/23.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI
import SnapshotSharedModels

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)

public final class ExpandingViewController: UIHostingController<EmergeModifierView>, ScrollExpansionProviding {

  var supportsExpansion: Bool {
    rootView.supportsExpansion
  }

  private let HeightExpansionTimeLimitInSeconds: UInt64 = 30

  private var didCall = false
  var previousHeight: CGFloat?
  var pendingContentSizeRetries: Int = 0
  var lastObservedContentHeight: CGFloat?
  var pendingIntrinsicSizeRetries: Int = 0
  var lastObservedIntrinsicSize: CGSize?

  var heightAnchor: NSLayoutConstraint?
  private var widthAnchor: NSLayoutConstraint?

  private var startTime: UInt64?
  private var timer: Timer?

  public var expansionSettled: ((EmergeRenderingMode?, Float?, Bool?, Bool?, Error?) -> Void)? {
    didSet { didCall = false }
  }

  init<Content: View>(rootView: Content) {
    super.init(rootView: EmergeModifierView(wrapped: rootView))

    if #available(iOS 16, *) {
      sizingOptions = .intrinsicContentSize
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    // Pin safe-area-derived layout to a stable, zeroed value up front.
    // UIHostingController otherwise resolves these insets across multiple
    // layout passes (the host's safeAreaInsets propagate from the window /
    // scene asynchronously), which translates the rendered content
    // vertically run-to-run on layouts that read directionalLayoutMargins
    // (e.g. screens with manual top/bottom padding via UILayoutGuide.
    // safeAreaLayoutGuide). Zeroing them eliminates that source of drift.
    view.insetsLayoutMarginsFromSafeArea = false
    view.directionalLayoutMargins = .zero
  }

  @MainActor required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func removeConstraints() {
    heightAnchor?.isActive = false
    widthAnchor?.isActive = false
    heightAnchor = nil
    widthAnchor = nil
    previousHeight = nil
    pendingContentSizeRetries = 0
    lastObservedContentHeight = nil
    pendingIntrinsicSizeRetries = 0
    lastObservedIntrinsicSize = nil
    didAppear = false
  }

  var hostFittingSize: CGSize? {
    // systemLayoutSizeFitting honors the active height/width anchors, which
    // makes it the canonical "what would this view want to render at" value
    // we're racing to stabilize. UILayoutFittingCompressedSize asks for the
    // smallest size satisfying constraints, matching the snapshot intent.
    view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
  }

  func setNeedsAnotherLayoutPass() {
    view.setNeedsLayout()
  }

  public func setupView(layout: PreviewLayout) {
    removeConstraints()
    switch layout {
    case let .fixed(width: width, height: height):
      widthAnchor = view.widthAnchor.constraint(equalToConstant: width)
      widthAnchor?.isActive = true
      heightAnchor = view.heightAnchor.constraint(equalToConstant: height)
      heightAnchor?.isActive = true
    default:
      let fittingSize = sizeThatFits(in: UIScreen.main.bounds.size)
      widthAnchor = view.widthAnchor.constraint(greaterThanOrEqualToConstant: fittingSize.width)
      widthAnchor?.isActive = true
      heightAnchor = view.heightAnchor.constraint(greaterThanOrEqualToConstant: fittingSize.height)
      heightAnchor?.isActive = true
    }
  }

  private func runCallback(_ error: Error? = nil) {
    guard !didCall else { return }

    let objectID = UInt(bitPattern: ObjectIdentifier(self).hashValue)
    NSLog("[snapshot-debug] event=runCallback id=%lx error=%@ fitting=%@",
          objectID,
          error?.localizedDescription ?? "nil",
          NSStringFromCGSize(hostFittingSize ?? .zero))
    didCall = true
    expansionSettled?(rootView.emergeRenderingMode, rootView.precision, rootView.accessibilityEnabled, rootView.appStoreSnapshot, error)
    stopAndResetTimer()
  }

  // Tracks whether viewDidAppear has fired. Layout passes that fire BEFORE
  // the view appears can read a transient view tree — e.g. a SwiftUI body
  // that returns EmptyView while @State is still nil and only mutates to its
  // final value inside viewDidAppear (`SelfRewardClaimViewController` was the
  // canary case: width collapsed 1418 → 786 in some captures because the
  // a11y legend depended on content the body wasn't yet rendering). Settling
  // on those passes locks in the wrong dimensions. Gating the settle loop
  // on this flag means we only commit after viewDidAppear has fired and any
  // state changes it triggers have had a chance to propagate.
  private var didAppear = false

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if didAppear {
      let objectID = UInt(bitPattern: ObjectIdentifier(self).hashValue)
      NSLog("[snapshot-debug] event=viewDidLayoutSubviews id=%lx didAppear=%d fitting=%@",
            objectID, didAppear ? 1 : 0,
            NSStringFromCGSize(hostFittingSize ?? .zero))
      updateScrollViewHeight()
    }
  }

  public override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    didAppear = true
    let objectID = UInt(bitPattern: ObjectIdentifier(self).hashValue)
    NSLog("[snapshot-debug] event=viewDidAppear id=%lx fitting=%@",
          objectID, NSStringFromCGSize(hostFittingSize ?? .zero))
    NSLog("[snapshot-debug] event=vc-info id=%lx parent=%@ rootViewType=%@",
          objectID,
          parent?.description ?? "nil",
          String(describing: type(of: rootView)))
    // Kick off the first settle attempt now that any viewDidAppear-driven
    // state mutations have had their chance to fire. The retry-on-instability
    // loop takes over from here via setNeedsLayout → next viewDidLayoutSubviews.
    updateScrollViewHeight()
  }

  public func updateScrollViewHeight() {
    // Timeout limit
    if timer == nil && heightAnchor != nil && supportsExpansion && firstScrollView != nil {
      startTimer()
    }

    guard expansionSettled != nil else {
      runCallback()
      return
    }

    updateHeight {
      runCallback()
    }
  }

//  MARK: - Timer

  func startTimer() {
      guard timer == nil else {
        print("Timer already exists")
        return
      }
      startTime = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
          guard let self,
                let start = startTime,
                clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start >= (HeightExpansionTimeLimitInSeconds * 1_000_000_000) else {
              return
          }
          let timeoutError = RenderingError.expandingViewTimeout(CGSize(width: UIScreen.main.bounds.size.width,
                                                                        height: firstScrollView?.visibleContentHeight ?? -1))
          NSLog("ExpandingViewController: Expanding Scroll View timed out. Current height is \(firstScrollView?.visibleContentHeight ?? -1)")
          runCallback(timeoutError)
      }
  }

  func stopAndResetTimer() {
      timer?.invalidate()
      timer = nil
      startTime = nil
  }

}
#endif
