//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest
import XCPlayground

// This is intentionally redefined here in the tests, as this string cannot change as it has clients which refer to it by the string value rather than by symbol.
let captureValueNotification = Notification.Name(rawValue: "XCPCaptureValue")

class CaptureValueTests: XCTestCase {
        
    // MARK: Deprecated XCPlaygroundPage
    
    func testPlaygroundPageCaptureValue() {
        let value = 321
        let identifier = "My Identifier 101"
        expectation(forNotification: captureValueNotification, object: XCPlaygroundPage.currentPage) { (notification) in
            guard let userInfoValue = notification.userInfo?["value"] as? Int else { return false }
            XCTAssertEqual(userInfoValue, value)
            
            guard let userInfoIdentifier = notification.userInfo?["identifier"] as? String else { return false }
            XCTAssertEqual(userInfoIdentifier, identifier)
            
            return true
        }
        XCPlaygroundPage.currentPage.captureValue(value: value, withIdentifier: identifier)
        waitForExpectations(timeout: 0.1, handler: nil)
    }
    
    // MARK: Deprecated Functions
    
    func testLegacyCaptureValue() {
        let value = 123
        let identifier = "My Identifier"
        expectation(forNotification: captureValueNotification, object: XCPlaygroundPage.currentPage) { (notification) in
            guard let userInfoValue = notification.userInfo?["value"] as? Int else { return false }
            XCTAssertEqual(userInfoValue, value)
            
            guard let userInfoIdentifier = notification.userInfo?["identifier"] as? String else { return false }
            XCTAssertEqual(userInfoIdentifier, identifier)
            return true
        }
        XCPCaptureValue(identifier: identifier, value: value)
        waitForExpectations(timeout: 0.1, handler: nil)
    }
    
    func testXCPExecutionShouldContinueIndefinitely() {
        XCTAssertEqual(XCPlaygroundPage.currentPage.needsIndefiniteExecution, XCPExecutionShouldContinueIndefinitely())
        XCPSetExecutionShouldContinueIndefinitely(continueIndefinitely: !XCPlaygroundPage.currentPage.needsIndefiniteExecution)
        XCTAssertEqual(XCPlaygroundPage.currentPage.needsIndefiniteExecution, XCPExecutionShouldContinueIndefinitely())
    }
    
}
