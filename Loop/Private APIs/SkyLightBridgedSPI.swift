//
//  SkyLightBridgedSPI.swift
//  Loop
//
//  Created by Kai Azim on 2026-07-02.
//  Thanks to Stephan Casas for originally showing me these private space-switching APIs :)
//

import CoreGraphics
import Darwin
import Foundation

@available(macOS 14.0, *)
enum SkyLightBridgedSPI {
    private enum OperationClassName {
        static let moveWindowsToManagedSpace = "SLSBridgedMoveWindowsToManagedSpaceOperation"
        static let copyManagedDisplaySpaces = "SLSBridgedCopyManagedDisplaySpacesOperation"
        static let copySpacesForWindows = "SLSBridgedCopySpacesForWindowsOperation"
    }

    private enum SelectorName {
        static let performWithWMBridgeDelegate = "performWithWMBridgeDelegate"
        static let initWithWindowsSpaceID = "initWithWindows:spaceID:"
        static let initWithOptionsWindows = "initWithOptions:windows:"
    }

    private static let objcMessageSend: UnsafeMutableRawPointer? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            return nil
        }

        return dlsym(handle, "objc_msgSend")
    }()

    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) -> Bool {
        guard let operation = makeMoveWindowsToManagedSpaceOperation(windowIDs: [windowID], spaceID: spaceID) else {
            return false
        }

        _ = performWithWMBridgeDelegate(operation)
        return true
    }

    static func copyManagedDisplaySpaces() -> [NSDictionary]? {
        guard let operationClass = NSClassFromString(OperationClassName.copyManagedDisplaySpaces) as? NSObject.Type else {
            return nil
        }

        let operation = operationClass.init()
        guard let result = performWithWMBridgeDelegate(operation),
              let propertyList = result.value(forKey: "propertyListArray") as? [NSDictionary]
        else {
            return nil
        }

        return propertyList
    }

    static func copySpaces(forWindows windowIDs: [CGWindowID], options: SLSSpaceMask) -> [NSNumber]? {
        guard let operation = makeCopySpacesForWindowsOperation(windowIDs: windowIDs, options: options),
              let result = performWithWMBridgeDelegate(operation),
              let numbers = result.value(forKey: "numbers") as? [NSNumber]
        else {
            return nil
        }

        return numbers
    }

    private static func performWithWMBridgeDelegate(_ operation: AnyObject) -> AnyObject? {
        guard let objcMessageSend else {
            return nil
        }

        let selector = NSSelectorFromString(SelectorName.performWithWMBridgeDelegate)
        guard operation.responds(to: selector) else {
            return nil
        }

        typealias PerformWithWMBridgeDelegate = @convention(c) (AnyObject, Selector) -> AnyObject?
        let performWithWMBridgeDelegate = unsafeBitCast(objcMessageSend, to: PerformWithWMBridgeDelegate.self)
        return performWithWMBridgeDelegate(operation, selector)
    }

    private static func allocate(_ operationClass: NSObject.Type) -> AnyObject? {
        guard let objcMessageSend else {
            return nil
        }

        typealias AllocateOperation = @convention(c) (AnyClass, Selector) -> AnyObject?
        let allocateOperation = unsafeBitCast(objcMessageSend, to: AllocateOperation.self)
        return allocateOperation(operationClass, NSSelectorFromString("alloc"))
    }

    private static func makeMoveWindowsToManagedSpaceOperation(
        windowIDs: [CGWindowID],
        spaceID: UInt64
    ) -> AnyObject? {
        guard let objcMessageSend,
              let operationClass = NSClassFromString(OperationClassName.moveWindowsToManagedSpace) as? NSObject.Type
        else {
            return nil
        }

        let initializer = NSSelectorFromString(SelectorName.initWithWindowsSpaceID)
        guard operationClass.instancesRespond(to: initializer),
              let allocatedOperation = allocate(operationClass)
        else {
            return nil
        }

        typealias InitMoveWindowsToManagedSpace = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        let initMoveWindowsToManagedSpace = unsafeBitCast(objcMessageSend, to: InitMoveWindowsToManagedSpace.self)
        return initMoveWindowsToManagedSpace(
            allocatedOperation,
            initializer,
            windowIDs.map { NSNumber(value: $0) } as NSArray,
            spaceID
        )
    }

    private static func makeCopySpacesForWindowsOperation(
        windowIDs: [CGWindowID],
        options: SLSSpaceMask
    ) -> AnyObject? {
        guard let objcMessageSend,
              let operationClass = NSClassFromString(OperationClassName.copySpacesForWindows) as? NSObject.Type
        else {
            return nil
        }

        let initializer = NSSelectorFromString(SelectorName.initWithOptionsWindows)
        guard operationClass.instancesRespond(to: initializer),
              let allocatedOperation = allocate(operationClass)
        else {
            return nil
        }

        typealias InitCopySpacesForWindows = @convention(c) (AnyObject, Selector, Int32, NSArray) -> AnyObject?
        let initCopySpacesForWindows = unsafeBitCast(objcMessageSend, to: InitCopySpacesForWindows.self)
        return initCopySpacesForWindows(
            allocatedOperation,
            initializer,
            options.rawValue,
            windowIDs.map { NSNumber(value: $0) } as NSArray
        )
    }
}
