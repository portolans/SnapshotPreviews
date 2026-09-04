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
  /// On by default: a view controller a preview built that is still alive after the render is the
  /// signature of a retain cycle inside that screen, and fails the preview's test. Override to
  /// return `false` to opt a suite out.
  open class func checksPreviewDeallocation() -> Bool {
    true
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
    // The render and its wait get their own autorelease pool: anything UIKit or the accessibility
    // capture autoreleases while this preview renders (including the previous preview's root tree,
    // which is torn down here) must be gone before the next preview judges this one. Without it those
    // references sit in the test method's pool until the method returns.
    autoreleasepool {
      let expectation = XCTestExpectation()
      strategy.render(preview: preview) { snapshotResult in
        result = snapshotResult
        expectation.fulfill()
      }
      wait(for: [expectation], timeout: 10)
    }
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
    if Self.checksPreviewDeallocation(), let previous = PreviewDeallocationTracker.previousPreview, previous.wasReleased {
      // This render replaced the previous preview in the window and drained what UIKit
      // autoreleased in the process, so a healthy preview's controllers are gone by now and cost
      // no wait. One still alive gets a bounded moment for whatever is finishing up (SwiftUI
      // dismantling a hosting-controller screen, a container's transition completing) and is then
      // reported in this test case, at the previous preview's own file and line. A real cycle never
      // lets go. (A render that failed before replacing the window's root leaves the previous
      // preview hosted, and unjudged.)
      let survivors = awaitRelease(previewNamed: previous.name) { previous.survivingViewControllers }
      if !survivors.isEmpty {
        recordLeak(previewNamed: previous.name, fileID: previous.fileID, line: previous.line, survivors: survivors, placement: previous.survivorPlacement, hostIsAlive: previous.hostIsAlive)
      }
    }
    #endif
  }

  #if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
  open override class func setUp() {
    super.setUp()
    MainActor.assumeIsolated { PreviewDeallocationTracker.reset() }
  }

  /// Judges, once per class, the previews that could not be judged one render later: the last one
  /// rendered (nothing came after it) and any whose controllers were still alive when judged.
  /// Releases the last render, waits a bounded moment once, then reports what is still alive.
  /// Judges the last preview the class rendered, which nothing came after. Recorded outside any
  /// test case, so the message carries the #Preview's file and line; XCTest may not surface a
  /// class-tearDown failure under parallel testing, which leaves the last preview of each test
  /// host a known gap. Nothing waits here: the only safe wait is a test case's own.
  open override class func tearDown() {
    if checksPreviewDeallocation() {
      MainActor.assumeIsolated {
        renderingStrategies[ObjectIdentifier(Self.self)]?.releaseRenderedPreview()
        if let current = PreviewDeallocationTracker.currentPreview, current.wasReleased,
           let description = leakDescription(previewNamed: current.name, survivors: current.survivingViewControllers, placement: current.survivorPlacement, hostIsAlive: current.hostIsAlive) {
          let location = [current.fileID, current.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
          XCTFail(location.isEmpty ? description : "\(location): \(description)")
        }
        PreviewDeallocationTracker.reset()
      }
    }
    super.tearDown()
  }

  /// The preview's controllers still alive after a bounded wait, which starts only if any is alive.
  ///
  /// The wait goes through this test case's own `wait(for:)`, the same call the render uses, from
  /// the same main-actor context. A standalone `XCTWaiter` from this context never returned and
  /// XCTest's stall watchdog aborted the host; a raw `RunLoop.run` deadlocked it under parallel
  /// testing. The expectation is fulfilled by a main-run-loop timer either when the controllers are
  /// gone or when the deadline passes, so the wait itself never records a timeout.
  // Takes plain values: SnapshotPreviewsCore is an implementation-only import, and a subclass in
  // another module cannot load any member, even a private one, whose signature names its types.
  //
  // Everything here runs on the main dispatch queue, never a run-loop timer. Inside a test's
  // `wait(for:)` from this main-actor context, main-queue blocks are delivered (the render's own
  // completion arrives that way) but run-loop timers never fire: a Timer-driven expectation, an
  // XCTNSPredicateExpectation, and XCTest's own wait timeout all left the host waiting until CI's
  // 30-minute limit.
  @MainActor
  private func awaitRelease(previewNamed name: String, survivors: @escaping @MainActor () -> [UIViewController]) -> [UIViewController] {
    guard !survivors().isEmpty else { return [] }
    let settled = XCTestExpectation(description: "\(name) released")
    let deadline = DispatchTime.now() + 2
    @MainActor func poll() {
      if survivors().isEmpty || DispatchTime.now() >= deadline {
        settled.fulfill()
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
      }
    }
    poll()
    wait(for: [settled], timeout: 5)
    return survivors()
  }

  // These helpers take plain values rather than tracker types: SnapshotPreviewsCore is an
  // implementation-only import, and a subclass in another module cannot load a member whose
  // signature mentions one of its types.
  @MainActor
  private func recordLeak(previewNamed name: String, fileID: String?, line: Int?, survivors: [UIViewController], placement: String, hostIsAlive: Bool) {
    guard let description = Self.leakDescription(previewNamed: name, survivors: survivors, placement: placement, hostIsAlive: hostIsAlive) else { return }
    var issue = XCTIssue(type: .assertionFailure, compactDescription: description)
    // Attribute the failure to the #Preview so it lands on the screen's own file rather than in
    // the harness.
    if let fileID, let line {
      issue.sourceCodeContext = XCTSourceCodeContext(location: XCTSourceCodeLocation(filePath: fileID, lineNumber: line))
    }
    record(issue)
  }

  @MainActor
  private static func leakDescription(previewNamed name: String, survivors: [UIViewController], placement: String, hostIsAlive: Bool) -> String? {
    guard !survivors.isEmpty else { return nil }
    let typeNames = Set(survivors.map { String(describing: type(of: $0)) }).sorted().joined(separator: ", ")
    let hostNote = hostIsAlive ? " The harness's own hosting controller is also still alive, which a leaked screen can cause." : ""
    return "\(typeNames) is still alive after preview \(name) was torn down. Something in its own graph retains it. Look for a stored closure that captures self (a cell registration or configuration handler whose nested closure is the only weak capture), a child holding its parent, or a subscription without a weak observer. [\(placement)]\(hostNote)"
  }
  #endif
}
