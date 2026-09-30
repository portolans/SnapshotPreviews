//
//  File.swift
//
//
//  Created by Noah Martin on 7/3/23.
//

#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit
import SwiftUI

struct UIViewControllerWrapper: UIViewControllerRepresentable {
  let builder: @MainActor () -> UIViewController

  init(_ builder: @escaping @MainActor () -> UIViewController) {
    self.builder = builder
  }

  func makeUIViewController(context: Context) -> UIViewController {
    let viewController = builder()
    PreviewDeallocationTracker.track(viewController)
    return viewController
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
}

struct UIViewWrapper: UIViewRepresentable {

  let builder: @MainActor () -> UIView

  init(_ builder: @escaping @MainActor () -> UIView) {
    self.builder = builder
  }

  func makeUIView(context: Context) -> UIView {
    builder()
  }

  func updateUIView(_ uiView: UIView, context: Context) { }

  // Frame-laid-out views measure themselves in sizeThatFits and have no intrinsicContentSize,
  // so without this they stretch to fill the device instead of rendering at their own size.
  @available(iOS 16.0, tvOS 16.0, *)
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
    // The host measures intrinsic size with unspecified dimensions; resolving those to zero
    // rather than infinity keeps a view that fills its proposal from measuring as unbounded.
    let fittingSize = uiView.sizeThatFits(CGSize(
      width: proposal.width ?? 0,
      height: proposal.height ?? 0
    ))
    // UIView's default sizeThatFits returns bounds.size, which is zero for a view that doesn't
    // measure itself; keep SwiftUI's default sizing for those.
    return fittingSize == .zero ? nil : fittingSize
  }
}
#endif
