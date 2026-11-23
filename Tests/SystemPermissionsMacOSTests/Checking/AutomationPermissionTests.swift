import AppKit
import CoreServices
import SystemPermissions
import XCTest

@testable import SystemPermissionsMacOS

final class AutomationPermissionTests: XCTestCase {
  func testStatusMappingPreservesConsentAndUnavailableStatesWithoutPrompting() {
    for prompt in [false, true] {
      XCTAssertEqual(automationPermissionResult(for: noErr, prompt: prompt), .supported(.granted))
      XCTAssertEqual(
        automationPermissionResult(for: OSStatus(errAEEventNotPermitted), prompt: prompt),
        .supported(.denied))
      XCTAssertEqual(
        automationPermissionResult(
          for: OSStatus(errAEEventWouldRequireUserConsent), prompt: prompt),
        .supported(.notDetermined))
      XCTAssertEqual(
        automationPermissionResult(for: OSStatus(-123456), prompt: prompt), .failed(.apiUnavailable)
      )
    }
  }

  func testStoppedAutomationTargetIsUnknownOnlyForPassiveStatus() {
    let status = OSStatus(procNotFound)
    XCTAssertEqual(automationPermissionResult(for: status, prompt: false), .supported(.unknown))
    XCTAssertEqual(automationPermissionResult(for: status, prompt: true), .failed(.apiUnavailable))
  }
}
