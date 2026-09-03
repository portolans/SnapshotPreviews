//
//  SnapshotTest.swift
//
//
//  Created by Noah Martin on 8/9/24.
//

import Foundation
@_implementationOnly import SnapshotPreviewsCore
import XCTest

/// A test class for generating snapshots of Xcode previews.
///
/// This class is designed to discover SwiftUI previews, render them, and generate snapshot images for testing purposes.
/// It provides mechanisms for filtering previews and supports different rendering strategies based on the platform.
open class SnapshotTest: PreviewBaseTest, PreviewFilters {
  
  /// Returns an optional array of preview names to be included in the snapshot testing. This also supports Regex format.
  ///
  /// Override this method to specify which previews should be included in the snapshot test.
  /// - Returns: An optional array of String containing the names of previews to be included.
  open class func snapshotPreviews() -> [String]? {
    nil
  }
  
  /// Returns an optional array of preview names to be excluded from the snapshot testing. This also supports Regex format.
  ///
  /// Override this method to specify which previews should be excluded from the snapshot test.
  /// - Returns: An optional array of String containing the names of previews to be excluded.
  open class func excludedSnapshotPreviews() -> [String]? {
    nil
  }
  
  #if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
  open class func setupA11y() -> ((UIViewController, UIWindow, PreviewLayout) -> UIView)? {
    return nil
  }

  /// Whether each preview's view controllers must deallocate once the preview is torn down.
  ///
  /// Override to return `true` to fail a preview's test when a view controller it built is still
  /// alive after the render — the signature of a retain cycle inside that screen. Off by default so
  /// existing suites keep their behavior until they opt in.
  open class func checksPreviewDeallocation() -> Bool {
    false
  }
  #endif

  /// Determines the appropriate rendering strategy based on the current platform and OS version.
  ///
  /// This method selects between UIKit, AppKit, and SwiftUI rendering strategies depending on the available frameworks and OS version.
  /// - Returns: A `RenderingStrategy` object suitable for the current environment.
  #if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
  private static func makeRenderingStrategy(a11y: ((UIViewController, UIWindow, PreviewLayout) -> UIView)?) -> RenderingStrategy {
    return UIKitRenderingStrategy(a11yWrapper: a11y)
  }
  #else
  private static func makeRenderingStrategy() -> RenderingStrategy {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      AppKitRenderingStrategy()
    #else
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
      SwiftUIRenderingStrategy()
    } else {
      preconditionFailure("Cannot snapshot on this device/os")
    }
    #endif
  }
    #endif
  /// Cached rendering strategy per concrete subclass. Two `SnapshotTest` subclasses in the same bundle each return their own `setupA11y()`,
  /// so the cache must key by class — otherwise whichever class runs first wins the cache and the other class silently reuses its strategy.
  private static var renderingStrategies: [ObjectIdentifier: RenderingStrategy] = [:]

  static private var previews: [SnapshotPreviewsCore.PreviewType] = []
  
  static private var previewCountForFileId: [String: Int] = [:]

  /// Discovers all relevant previews based on inclusion and exclusion filters. Subclasses should NOT override this method.
  ///
  /// This method uses `FindPreviews` to locate all previews, applying any specified filters.
  /// - Returns: An array of `DiscoveredPreview` objects representing the found previews.
  @MainActor
  override class func discoverPreviews() -> [DiscoveredPreview] {
    previews = FindPreviews.findPreviews(included: Self.snapshotPreviews(), excluded: Self.excludedSnapshotPreviews())
    
    for preview in previews {
        guard let fileId = preview.fileID else { continue }
        previewCountForFileId[fileId, default: 0] += 1
    }
    
    return previews.map { DiscoveredPreview.from(previewType: $0) }
  }

  /// Tests a specific preview by rendering it and generating a snapshot. Subclasses should NOT override this method.
  ///
  /// This method renders the specified preview using the appropriate rendering strategy,
  /// creates a snapshot image, and attaches it to the test results.
  ///
  /// - Parameter discoveredPreview: A `DiscoveredPreviewAndIndex` object representing the preview to be tested.
  @MainActor
  override func testPreview(_ discoveredPreview: DiscoveredPreviewAndIndex) {
    let previewType = Self.previews.first { $0.typeName == discoveredPreview.preview.typeName }
    guard let previewType = previewType else {
      XCTFail("Preview type not found")
      return
    }

    let preview = previewType.previews[discoveredPreview.index]
    var result: SnapshotResult? = nil
    let strategy: RenderingStrategy
    let strategyKey = ObjectIdentifier(Self.self)
    if let cached = Self.renderingStrategies[strategyKey] {
      strategy = cached
    } else {
#if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
      strategy = Self.makeRenderingStrategy(a11y: Self.setupA11y())
      #else
      strategy = Self.makeRenderingStrategy()
      #endif
      Self.renderingStrategies[strategyKey] = strategy
    }
    var typeFileName = previewType.displayName
    if let fileId = previewType.fileID, let lineNumber = previewType.line {
      typeFileName = Self.previewCountForFileId[fileId]! > 1 ? "\(fileId):\(lineNumber)" : fileId
    }
    let previewName = "\(typeFileName)_\(preview.displayName ?? String(discoveredPreview.index))"
    #if canImport(UIKit) && !os(watchOS)
    PreviewDeallocationTracker.beginPreview(name: previewName, fileID: previewType.fileID, line: previewType.line)
    #endif
    let expectation = XCTestExpectation()
    strategy.render(preview: preview) { snapshotResult in
      result = snapshotResult
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 10)
    guard let result else {
      XCTFail("Did not render")
      return
    }

    do {
      let attachment = try XCTAttachment(image: result.image.get())
      attachment.name = previewName
      attachment.lifetime = .keepAlways
      add(attachment)
    } catch {
      XCTFail("Error \(error)")
    }

    #if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
    if Self.checksPreviewDeallocation(), let previous = PreviewDeallocationTracker.previousPreview {
      // This render replaced the previous preview in the window, so its controllers have had a
      // whole render cycle to go away. Whatever is left is retained by its own graph, unless the
      // platform still holds the harness's own hosting controller, in which case the check can
      // say nothing about the screen and is skipped rather than failed.
      if previous.hostIsAlive {
        Self.inconclusivePreviewCount += 1
      } else {
        recordLeak(previewNamed: previous.name, fileID: previous.fileID, line: previous.line, survivors: previous.survivingViewControllers)
      }
    }
    #endif
  }

  #if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
  /// The last preview a process renders has nothing after it to trigger the deferred check, so
  /// release it here and give UIKit a bounded moment to let go before judging.
  open override class func tearDown() {
    if checksPreviewDeallocation() {
      MainActor.assumeIsolated {
        guard let current = PreviewDeallocationTracker.currentPreview else { return }
        renderingStrategies[ObjectIdentifier(Self.self)]?.releaseRenderedPreview()
        // Wait through XCTest rather than by spinning the run loop ourselves: under parallel
        // testing a raw `RunLoop.run` inside the harness deadlocked the test host.
        let released = XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { current.survivingViewControllers.isEmpty }
          },
          object: nil
        )
        _ = XCTWaiter().wait(for: [released], timeout: 2)
        if current.hostIsAlive {
          inconclusivePreviewCount += 1
        } else if let description = leakDescription(previewNamed: current.name, survivors: current.survivingViewControllers) {
          XCTFail(description)
        }
        if inconclusivePreviewCount > 0 {
          // Not a failure: a runtime that keeps hosting controllers alive (the iOS 18 simulator
          // does) gives this check nothing to judge. Say so once so the silence is not mistaken
          // for coverage.
          print("Preview deallocation check: inconclusive for \(inconclusivePreviewCount) preview(s) whose hosting controller the platform kept alive.")
        }
      }
    }
    super.tearDown()
  }

  private static var inconclusivePreviewCount = 0

  // These helpers take plain values rather than tracker types: SnapshotPreviewsCore is an
  // implementation-only import, and a subclass in another module cannot load a member whose
  // signature mentions one of its types.
  @MainActor
  private func recordLeak(previewNamed name: String, fileID: String?, line: Int?, survivors: [UIViewController]) {
    guard let description = Self.leakDescription(previewNamed: name, survivors: survivors) else { return }
    var issue = XCTIssue(type: .assertionFailure, compactDescription: description)
    // Attribute the failure to the #Preview so it lands on the screen's own file rather than in
    // the harness.
    if let fileID, let line {
      issue.sourceCodeContext = XCTSourceCodeContext(location: XCTSourceCodeLocation(filePath: fileID, lineNumber: line))
    }
    record(issue)
  }

  @MainActor
  private static func leakDescription(previewNamed name: String, survivors: [UIViewController]) -> String? {
    guard !survivors.isEmpty else { return nil }
    let typeNames = Set(survivors.map { String(describing: type(of: $0)) }).sorted().joined(separator: ", ")
    return "\(typeNames) is still alive after preview \(name) was torn down. Something in its own graph retains it. Look for a stored closure that captures self (a cell registration or configuration handler whose nested closure is the only weak capture), a child holding its parent, or a subscription without a weak observer."
  }
  #endif
}
