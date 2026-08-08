//===--- LogEntry+Reflection.swift ----------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics

fileprivate class DebugQuickLookObjectHook: NSObject {
    @objc(debugQuickLookObject) func debugQuickLookObject() -> AnyObject? { return nil }
}

fileprivate let emptyNameString = ""

extension LogEntry {
    init(describing instance: Any, name: String? = nil, policy: LogPolicy) throws {
        self = try .init(describing: instance, name: name ?? emptyNameString, typeName: nil, policy: policy, currentDepth: 0)
    }
    
    fileprivate init(describing instance: Any, name: String, typeName passedInTypeName: String?, policy: LogPolicy, currentDepth: Int) throws {
        guard currentDepth <= policy.maximumDepth else {
            self = .gap
            return
        }

        do {
            let existentialContainer = AnyExistentialContainer(instance)

            guard let instanceType = existentialContainer.type else {
                self = .error(reason: "Value does not contain a type")
                return
            }

            if instanceType is AnyClass && existentialContainer.fixedSizeBuffer.0 == nil {
                self = .structured(name: name, typeName: passedInTypeName ?? normalizedName(of: instanceType), summary: "nil", totalChildrenCount: 0, children: [], disposition: .aggregate)
                return
            }
        }

        var _mirrorStorage: Mirror? = nil
        var mirror: Mirror {
            if let mirror = _mirrorStorage {
                return mirror
            }

            let mirror = Mirror(reflecting: instance)
            _mirrorStorage = mirror
            return mirror
        }

        var _typeNameStorage: String? = nil
        var typeName: String {
            if let typeName = _typeNameStorage {
                return typeName
            }

            let typeName = passedInTypeName ?? normalizedName(of: type(of: instance))
            _typeNameStorage = typeName
            return typeName
        }

        if let customPlaygroundDisplayConvertible = instance as? CustomPlaygroundDisplayConvertible {
            self = try .init(describing: customPlaygroundDisplayConvertible.playgroundDescription, name: name, typeName: typeName, policy: policy, currentDepth: currentDepth)
        }
        
        else if let customOpaqueLoggable = instance as? CustomOpaqueLoggable {
            self = try .opaque(name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), preferBriefSummary: false, representation: customOpaqueLoggable.opaqueRepresentation())
        }
        
        else if let customQuickLookable = instance as? _CustomPlaygroundQuickLookable {
            self = try .init(playgroundQuickLook: customQuickLookable.customPlaygroundQuickLook, name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror))
        }
        else if let defaultQuickLookable = instance as? __DefaultCustomPlaygroundQuickLookable {
            self = try .init(playgroundQuickLook: defaultQuickLookable._defaultCustomPlaygroundQuickLook, name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror))
        }
            
        else if let debugQuickLookObjectMethod = (instance as AnyObject).debugQuickLookObject, let debugQuickLookObject = debugQuickLookObjectMethod() {
            self = try .init(describing: debugQuickLookObject, name: name, typeName: typeName, policy: policy, currentDepth: currentDepth)
        }
            
        else {
            switch CFGetTypeID(instance as CFTypeRef) {
            case CGColor.typeID:
                let cgColor = instance as! CGColor
                self = .opaque(name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), preferBriefSummary: false, representation: cgColor.opaqueRepresentation())
            case CGImage.typeID:
                let cgImage = instance as! CGImage
                self = .opaque(name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), preferBriefSummary: false, representation: cgImage.opaqueRepresentation())
            default:
                if mirror.displayStyle == .optional && mirror.children.count == 1 {
                    self = try .init(describing: mirror.children.first!.value, name: name, typeName: nil, policy: policy, currentDepth: currentDepth)
                }
                else {
                    self = .init(structureFrom: mirror, name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), policy: policy, currentDepth: currentDepth)
                }
            }
        }
    }
    
    private init(playgroundQuickLook: _PlaygroundQuickLook, name: String, typeName: String, summary: String) throws {
        self = try .opaque(name: name, typeName: typeName, summary: summary, preferBriefSummary: false, representation: playgroundQuickLook.opaqueRepresentation())
    }
    
    fileprivate static let superclassLogEntryName = "super"
    
    fileprivate init(structureFrom mirror: Mirror, name: String, typeName: String, summary: String, policy: LogPolicy, currentDepth: Int) {
        self = .structured(name: name,
                           typeName: typeName,
                           summary: summary,
                           totalChildrenCount: mirror.totalChildCount,
                           children: mirror.childEntries(using: policy, currentDepth: currentDepth),
                           disposition: .init(displayStyle: mirror.displayStyle)
        )
    }
}

extension LogEntry.StructuredDisposition {
    fileprivate init(displayStyle: Mirror.DisplayStyle?) {
        guard let displayStyle = displayStyle else {
            self = .container
            return
        }
        
        switch displayStyle {
        case .`struct`:
            self = .`struct`
        case .`class`:
            self = .`class`
        case .`enum`:
            self = .`enum`
        case .tuple:
            self = .tuple
        case .optional:
            self = .aggregate
        case .collection:
            self = .indexContainer
        case .dictionary:
            self = .keyContainer
        case .set:
            self = .membershipContainer
        @unknown default:
            self = .container
        }
    }
}

extension Mirror {
    fileprivate var totalChildCount: Int {
        if superclassMirror != nil {
            return Int(children.count) + 1
        }
        else {
            return Int(children.count)
        }
    }

    fileprivate func childEntries(using policy: LogPolicy, currentDepth: Int) -> [LogEntry] {
        let childPolicy: LogPolicy.ChildPolicy = {
            switch self.displayStyle ?? .struct {
            case .class, .struct, .tuple, .enum:
                return policy.aggregateChildPolicy
            case .optional, .collection, .dictionary, .set:
                return policy.containerChildPolicy
            @unknown default:
                return policy.aggregateChildPolicy
            }
        }()

        let childDepth: Int = {
            switch self.displayStyle ?? .struct {
            case .optional, .dictionary:
                return currentDepth
            case .class, .struct, .tuple, .enum, .collection, .set:
                return currentDepth + 1
            @unknown default:
                return currentDepth + 1
            }
        }()

        func logEntry(forChild child: Mirror.Child) -> LogEntry {
            do {
                return try LogEntry(describing: child.value, name: child.label ?? emptyNameString, typeName: nil, policy: policy, currentDepth: childDepth)
            }
            catch let LoggingError.failedToGenerateOpaqueRepresentation(reason) {
                return LogEntry.error(reason: reason)
            }
            catch LoggingError.encodingFailure {
                fatalError("Encoding failures should not be encountered while generating LogEntry values")
            }
            catch let LoggingError.otherFailure(reason) {
                return LogEntry.error(reason: reason)
            }
            catch {
                return LogEntry.error(reason: "Unknown error encountered when generating log entry")
            }
        }

        func logEntriesForAllChildren() -> [LogEntry] {
            let childEntries = children.map(logEntry(forChild:))
            if let superclassMirror = superclassMirror {
                return [superclassMirror.logEntry(named: LogEntry.superclassLogEntryName, usingPolicy: policy, depth: childDepth)] + childEntries
            }
            else {
                return childEntries
            }
        }

        func logEntries(forFirstChildren count: Int) -> [LogEntry] {
            let numberOfChildren: Int
            let superclassEntries: [LogEntry]
            if let superclassMirror = superclassMirror {
                superclassEntries = [superclassMirror.logEntry(named: LogEntry.superclassLogEntryName, usingPolicy: policy, depth: childDepth)]
                numberOfChildren = count - 1
            }
            else {
                superclassEntries = []
                numberOfChildren = count
            }

            return superclassEntries + children.prefix(numberOfChildren).map(logEntry(forChild:))
        }

        func logEntries(forLastChildren count: Int) -> [LogEntry] {
            return children.suffix(count).map(logEntry(forChild:))
        }

        guard childDepth <= policy.maximumDepth else {
            return [.gap]
        }

        switch childPolicy {
        case .all:
            return logEntriesForAllChildren()
        case let .head(count):
            if totalChildCount <= count {
                return logEntriesForAllChildren()
            }

            return logEntries(forFirstChildren: count) + [LogEntry.gap]
        case let .headTail(headCount, tailCount):
            if totalChildCount <= headCount + tailCount {
                return logEntriesForAllChildren()
            }

            return logEntries(forFirstChildren: headCount) + [LogEntry.gap] + logEntries(forLastChildren: tailCount)
        case .none:
            return []
        }
    }

    fileprivate func logEntry(named name: String, usingPolicy policy: LogPolicy, depth: Int) -> LogEntry {
        let subjectTypeName = normalizedName(of: self.subjectType)
        return LogEntry(structureFrom: self, name: name, typeName: subjectTypeName, summary: subjectTypeName, policy: policy, currentDepth: depth)
    }
}

fileprivate struct AnyExistentialContainer {
    var fixedSizeBuffer: (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?)
    var type: Any.Type?

    init(_ instance: Any) {
        assert(MemoryLayout<AnyExistentialContainer>.size == MemoryLayout<Any>.size)
        assert(MemoryLayout<AnyExistentialContainer>.alignment == MemoryLayout<Any>.alignment)
        assert(MemoryLayout<AnyExistentialContainer>.stride == MemoryLayout<Any>.stride)
        assert(MemoryLayout<AnyExistentialContainer>.offset(of: \AnyExistentialContainer.fixedSizeBuffer) == 0)
        assert(MemoryLayout<(UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?)>.size == (3 * MemoryLayout<UnsafeRawPointer?>.size))
        assert(MemoryLayout<AnyExistentialContainer>.offset(of: \AnyExistentialContainer.type) == MemoryLayout<(UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?)>.size)
        assert(_isPOD(Any.Type?.self))
        assert(_isPOD(AnyExistentialContainer.self))

        self = withUnsafeBytes(of: instance) { bytes in
            return bytes.load(as: AnyExistentialContainer.self)
        }
    }
}

/// Construct the summary for `instance`.
///
/// In precedence order, the rules are:
///   - If the instance is itself a `String`, return the instance
///   - If the instance conforms to `CustomDebugStringConvertible`, use `String(reflecting:)` for debug output
///   - If the instance conforms to `CustomStringConvertible` (but not debug), use `String(describing:)` to call `.description` directly without added decoration
///   - If the instance is an enum (as reported using Mirror), use `String(describing:)`
///   - Otherwise, use the normalized type name
fileprivate func generateSummary(for instance: Any, withTypeName typeNameProvider: @autoclosure () -> String, using mirrorProvider: @autoclosure () -> Mirror) -> String {
    if let string = instance as? String {
        return string
    }

    // Use String(reflecting:) only for CustomDebugStringConvertible, which is intended for debug output.
    // For CustomStringConvertible, use String(describing:) which calls .description directly without
    // adding surrounding quotes or other debug decoration that would confuse Playground sidebar output.
    if instance is CustomDebugStringConvertible {
        return String(reflecting: instance)
    }

    if instance is CustomStringConvertible {
        return String(describing: instance)
    }

    let mirror = mirrorProvider()
    if mirror.displayStyle == .enum {
        return String(describing: instance)
    }

    return typeNameProvider()
}
