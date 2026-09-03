//
//  LeaksHold.swift
//
//
//  Created by Dan Federman on 9/3/26.
//

import Foundation
import XCTest

/// Keeps the test host alive after its last test so an external memory tool can inspect it.
///
/// Apple's `leaks` finds unreachable retain cycles among any objects in a process, which is what a
/// per-controller deallocation check cannot see: a presenter and a service that hold each other
/// outlive the screen that built them. The tool has to run against a live process, so when
/// `PREVIEW_LEAKS_HOLD_DIR` names a directory the bundle writes `<pid>.hold` there once every test
/// has finished and waits for `<pid>.done` (or `PREVIEW_LEAKS_HOLD_TIMEOUT` seconds, default 180)
/// before letting the process exit. A sidecar that watches the directory runs `leaks <pid>`,
/// writes its report next to the marker, and touches `.done`.
final class LeaksHold: NSObject, XCTestObservation {
  static let shared = LeaksHold()

  /// Registers the observer once, and only when the environment asks for the hold.
  static func registerIfRequested() {
    guard !didRegister, ProcessInfo.processInfo.environment["PREVIEW_LEAKS_HOLD_DIR"] != nil else { return }
    didRegister = true
    XCTestObservationCenter.shared.addTestObserver(shared)
  }

  func testBundleDidFinish(_ testBundle: Bundle) {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["PREVIEW_LEAKS_HOLD_DIR"] else { return }
    let timeout = environment["PREVIEW_LEAKS_HOLD_TIMEOUT"].flatMap(TimeInterval.init) ?? 180
    let pid = ProcessInfo.processInfo.processIdentifier
    let holdURL = URL(fileURLWithPath: directory).appendingPathComponent("\(pid).hold")
    let doneURL = URL(fileURLWithPath: directory).appendingPathComponent("\(pid).done")
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    guard (try? Data().write(to: holdURL)) != nil else { return }

    // Spinning the run loop here is fine: no test is running, so nothing else owns the main
    // thread, unlike the in-test drains that deadlocked under parallel testing.
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: doneURL.path), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
  }

  private static var didRegister = false
}
