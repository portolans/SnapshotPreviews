//
//  PreviewBaseTest.swift
//
//
//  Created by Noah Martin on 8/9/24.
//

import Foundation
import XCTest

struct DiscoveredPreview {
  let typeName: String
  let displayName: String?
  let devices: [String]
  let orientations: [String]
  let numberOfPreviews: Int
}

struct DiscoveredPreviewAndIndex {
  let preview: DiscoveredPreview
  let index: Int
}

var previews: [DiscoveredPreviewAndIndex] = []

@objc(EMGPreviewBaseTest)
open class PreviewBaseTest: XCTestCase {

  static var signatureCreator: NSObject?

  open override class var defaultTestSuite: XCTestSuite {
    // EMGInvocationCreator's +load tries to install our testInvocations
    // swizzle, but its `[NSClassFromString("EMGPreviewBaseTest")
    // performSelector:@selector(swizzle:)]` call is a silent no-op when this
    // Swift class isn't yet registered with the Obj-C runtime — a load-order
    // race between the Obj-C and Swift halves of the package. When the race
    // is lost, signatureCreator stays nil, every PreviewBaseTest subclass
    // falls through to XCTestCase's default testInvocations (which finds no
    // static test* methods on these dynamic classes), and the bundle exits
    // cleanly having run zero previews. Force the swizzle here, where this
    // class is guaranteed to be realized (defaultTestSuite is being called
    // on it). Idempotent — the swizzle's class_addMethod returns false if
    // the method is already installed.
    ensureSwizzleInstalled()
    return super.defaultTestSuite
  }

  private static func ensureSwizzleInstalled() {
    guard signatureCreator == nil,
          let creator = NSClassFromString("EMGInvocationCreator")
    else {
      return
    }
    // AnyClass instances are NSObject-compatible at the Obj-C level —
    // swizzle(_:) only reads its argument as a class. Bridging via
    // `as AnyObject as! NSObject` keeps this in safe Swift territory.
    swizzle(creator as AnyObject as! NSObject)
  }

  @objc
  static func swizzle(_ signatureCreator: NSObject) {
    self.signatureCreator = signatureCreator
    let originalSelector = NSSelectorFromString("testInvocations")
    let swizzledSelector = #selector(swizzled_testInvocations)
    let originalMethod = class_getClassMethod(XCTestCase.self, originalSelector)
    let swizzledMethod = class_getClassMethod(PreviewBaseTest.self, swizzledSelector)
    guard let originalMethod, let swizzledMethod else {
      print("Method not found")
      return
    }

    let swizzledImp = method_getImplementation(swizzledMethod)
    let currentClass: AnyClass = object_getClass(PreviewBaseTest.self)!
    class_addMethod(currentClass, originalSelector, swizzledImp, method_getTypeEncoding(originalMethod))
  }

  @objc @MainActor
  static func swizzled_testInvocations() -> [AnyObject] {
    let className = NSStringFromClass(self)
    // Only support running this test if it’s a subclass outside of the SnapshottingTests module
    if className == "EMGPreviewBaseTest" || className.hasPrefix("SnapshottingTests.") {
      return []
    }

    let dynamicTestSelectors = addMethods().sorted()
    var invocations: [AnyObject] = []
    guard let signatureCreator else {
      return invocations
    }
    for testName in dynamicTestSelectors {
      let invocation = signatureCreator.perform(NSSelectorFromString("create:"), with: testName).takeRetainedValue() as! NSObject
      invocations.append(invocation)
    }
    return invocations
  }

    @MainActor
    class func addMethods() -> [String] {
      var dynamicTestSelectors: [String] = []
      let discoveredPreviews = discoverPreviews()
      previews = []
      var i = 0

      let currentDeviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]

      for discoveredPreview in discoveredPreviews {
        let typeName = discoveredPreview.typeName
        let displayName = discoveredPreview.displayName ?? typeName
        let count = discoveredPreview.numberOfPreviews

        for j in 0..<count {
          // Filter out device specific previews whose device name doesn't match the currently selected one
          if currentDeviceName != nil {
            let specifiedPreviewDevice = discoveredPreview.devices[j]
            guard specifiedPreviewDevice.isEmpty || specifiedPreviewDevice == currentDeviceName else {
              continue
            }
          }

          let orientation = discoveredPreview.orientations[j]
          let testSelectorName = "\(orientation)-\(displayName)-\(j)-\(i)"
          dynamicTestSelectors.append(testSelectorName)

          let preview = DiscoveredPreviewAndIndex(preview: discoveredPreview, index: j)
          previews.append(preview)

          let sel = NSSelectorFromString(testSelectorName)
          let rawPtr = unsafeBitCast(dynamicTestMethod, to: UnsafeRawPointer.self)
          let success = class_addMethod(self, sel, OpaquePointer(rawPtr), "v@:")
          if !success {
            print("Error adding method \(testSelectorName)")
          }
          i += 1
        }
      }

      return dynamicTestSelectors
    }

    @MainActor
    func testPreview(_ preview: DiscoveredPreviewAndIndex) {
      print("This should be implemented by a subclass")
    }

    @MainActor
    class func discoverPreviews() -> [DiscoveredPreview] {
      print("This should be implemented by a subclass")
      return []
    }
}

@MainActor
private let dynamicTestMethod: @convention(c) (AnyObject, Selector) -> Void = { (self, _cmd) in
    let selectorName = NSStringFromSelector(_cmd)
    let testNumber = selectorName.components(separatedBy: "-").last ?? "0"
    let index = Int(testNumber) ?? 0
    let preview = previews[index]
    if let selfAsBase = self as? PreviewBaseTest {
        selfAsBase.testPreview(preview)
    }
}
