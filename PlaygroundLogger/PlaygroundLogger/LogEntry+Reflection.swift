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
            // We're trying to log an instance that is "too deep"; as a result, we need to just return a gap.
            self = .gap
            return
        }

        // In Swift, it is undefined behavior to have a value of non-Optional class type which is set to nil.
        // Unfortunately, these can be encountered in the wild; the most common example is an incorrect Objective-C nullability annotation.
        // To prevent PlaygroundLogger from triggering undefined behavior (which, as of this writing, causes a crash in the Swift runtime), perform a safety check before proceeding with logging.
        do {
            // First, parse the existential container for `instance` so we can examine its contents directly.
            let existentialContainer = AnyExistentialContainer(instance)

            // Next, get the type of `instance` which is stored in the existential container.
            guard let instanceType = existentialContainer.type else {
                // The existential container does not contain a type, which is invalid.
                // Rather than crash by trying to proceed along from here, return an error LogEntry.
                self = .error(reason: "Value does not contain a type")
                return
            }

            // If `instance` contains a non-Optional class type (e.g. AnyObject), then `instanceType is AnyClass` will be true.
            // If `instance` contains an Optional class type (e.g. AnyObject? aka Optional<AnyObject>), then `instanceType is AnyClass` will be false, as Optional is *not* a class.
            //
            // If `instance` contains a non-Optional class type, then the first pointer in the existential container's buffer will be the object pointer. We can check to see if that pointer is nil to see if the object is nil.
            if instanceType is AnyClass && existentialContainer.fixedSizeBuffer.0 == nil {
                // `instance` is broken. As a result, return a log entry which indicates that the value is nil.
                self = .structured(name: name, typeName: passedInTypeName ?? normalizedName(of: instanceType), summary: "nil", totalChildrenCount: 0, children: [], disposition: .aggregate)
                return
            }
        }

        // Lazily-load the Mirror for this instance. (This is factored out this way as the Mirror is needed in a few different code paths.)
        var _mirrorStorage: Mirror? = nil
        var mirror: Mirror {
            if let mirror = _mirrorStorage {
                return mirror
            }

            let mirror = Mirror(reflecting: instance)
            _mirrorStorage = mirror
            return mirror
        }

        // Lazily-load the normalized type name for this instance. (This is factored out this way as the type name is expensive to compute, so we only want to do it once.)
        var _typeNameStorage: String? = nil
        var typeName: String {
            if let typeName = _typeNameStorage {
                return typeName
            }

            let typeName = passedInTypeName ?? normalizedName(of: type(of: instance))
            _typeNameStorage = typeName
            return typeName
        }

        // For types which conform to the `CustomPlaygroundDisplayConvertible` protocol, get their custom representation and then run it back through the initializer.
        if let customPlaygroundDisplayConvertible = instance as? CustomPlaygroundDisplayConvertible {
            self = try .init(describing: customPlaygroundDisplayConvertible.playgroundDescription, name: name, typeName: typeName, policy: policy, currentDepth: currentDepth)
        }
        
        // For types which conform to the `CustomOpaqueLoggable` protocol, get their custom representation and construct an opaque log entry. (This is checked *second* so that user implementations of `CustomPlaygroundDisplayConvertible` are honored over this framework's implementations of `CustomOpaqueLoggable`.)
        else if let customOpaqueLoggable = instance as? CustomOpaqueLoggable {
            // TODO: figure out when to set `preferBriefSummary` to true
            self = try .opaque(name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), preferBriefSummary: false, representation: customOpaqueLoggable.opaqueRepresentation())
        }
        
        // For types which conform to the legacy `CustomPlaygroundQuickLookable` or `_DefaultCustomPlaygroundQuickLookable` protocols, get their `PlaygroundQuickLook` and use that for logging.
        else if let customQuickLookable = instance as? _CustomPlaygroundQuickLookable {
            self = try .init(playgroundQuickLook: customQuickLookable.customPlaygroundQuickLook, name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror))
        }
        else if let defaultQuickLookable = instance as? __DefaultCustomPlaygroundQuickLookable {
            self = try .init(playgroundQuickLook: defaultQuickLookable._defaultCustomPlaygroundQuickLook, name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror))
        }
            
        // If a type implements the `debugQuickLookObject()` Objective-C method, then get their debug quick look object and use that for logging (by passing it back through this initializer).
        else if let debugQuickLookObjectMethod = (instance as AnyObject).debugQuickLookObject, let debugQuickLookObject = debugQuickLookObjectMethod() {
            self = try .init(describing: debugQuickLookObject, name: name, typeName: typeName, policy: policy, currentDepth: currentDepth)
        }
            
        // Otherwise, first check if this is an interesting CF type before logging structure.
        // This works around SR-2289/<rdar://problem/27116100>.
        else {
            switch CFGetTypeID(instance as CFTypeRef) {
            case CGColor.typeID:
                let cgColor = instance as! CGColor
                self = .opaque(name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), preferBriefSummary: false, representation: cgColor.opaqueRepresentation())
            case CGImage.typeID:
                let cgImage = instance as! CGImage
                self = .opaque(name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), preferBriefSummary: false, representation: cgImage.opaqueRepresentation())
            default:
                // This isn't one of the CF types we want to specially handle, so the log entry should just reflect the instance's structure.

                if mirror.displayStyle == .optional && mirror.children.count == 1 {
                    // If the mirror displays as an Optional and has exactly one child, then we want to unwrap the optionality and generate a log entry for the child.
                    self = try .init(describing: mirror.children.first!.value, name: name, typeName: nil, policy: policy, currentDepth: currentDepth)
                }
                else {
                    // Otherwise, we want to generate a log entry with the structure from the mirror.
                    self = .init(structureFrom: mirror, name: name, typeName: typeName, summary: generateSummary(for: instance, withTypeName: typeName, using: mirror), policy: policy, currentDepth: currentDepth)
                }
            }
        }
    }
    
    private init(playgroundQuickLook: _PlaygroundQuickLook, name: String, typeName: String, summary: String) throws {
        // TODO: figure out when to set `preferBriefSummary` to true
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
            // If this is an unknown display style, default to .container.
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
                // If this is an unknown display style, default to treating it like an aggregate.
                return policy.aggregateChildPolicy
            }
        }()

        let childDepth: Int = {
            switch self.displayStyle ?? .struct {
            case .optional, .dictionary:
                // We don't consume a level of depth for optionals or dictionaries.
                // We don't want optional to count as a level of depth as we would quickly end up with gaps.
                // We don't want dictionary to count as a level of depth as dictionary is modeled as a collection of (key, value) pairs, and we don't want to lose a level due to the pairs themselves consuming a level, so for ease of bookkeeping the dictionary level is counted as not consuming a level.
                return currentDepth
            case .class, .struct, .tuple, .enum, .collection, .set:
                return currentDepth + 1
            @unknown default:
                // If this is an unknown display style, assume it consumes a level of depth.
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

        // Ensure that our children are loggable (i.e. their depth is not prohibited by our current policy).
        // If our children **are** too deep, then simply return a single gap as our children.
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

/// A struct representing the memory contents of an `Any` -- the existential container for the `Any` rather than the value itself contained in the `Any`.
///
/// The memory layout of an existential container is part of Swift's ABI. It is defined as:
///
/// - Three words of fixed storage for an inline buffer containing either the value or a pointer to a box containing the value
/// - One word containing a pointer to the type metadata for the value stored in the existential
/// - Zero or more words containing pointers to the protocol witness tables for the protocols to which the existential is constrained
///
/// Since `Any` is an existential with no protocol constraints, it ultimately is a four-word value where the first three words are a fixed-size buffer
/// and the last word is a pointer to the type metadata.
///
/// This struct stores the fixed-size buffer as three `UnsafeRawPointer?` values.
/// An `Any.Type?` (aka `Optional<Any.Type>`, not `Optional<Any>.Type`) in Swift is itself a pointer to the type metadata, so this struct loads that pointer as an `Any.Type?` for examination.
fileprivate struct AnyExistentialContainer {
    /// A fixed-size, three-word buffer containing the value or a pointer to a box containing the value stored in this existential container.
    ///
    /// The contents of this buffer must only be interpreted in the context of a particular type.
    /// For example, if this existential container contains an object, the first word will contain the pointer to that object while the contents of the other two words are undefined.
    var fixedSizeBuffer: (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?)

    /// The type of the value stored in this existential container.
    ///
    /// This can be used to interpret the value stored in `fixedSizeBuffer`.
    /// For example, if this existential container contains an object, `self.type is AnyClass` will be true.
    var type: Any.Type?

    /// Initializes a new `AnyExistentialContainer` with the contents of `instance`.
    ///
    /// This initializer does this with direct memory access to load the `Any` as its container rather than as the value contained in the `Any`.
    ///
    /// - important: This initializer does not use the Swift runtime to interact with the contents of `instance`.
    ///              It is **critical** that this remain true so that an untrusted `Any` can be examined by PlaygroundLogger before proceeding with logging.
    ///
    /// - parameter instance: The `Any` whose existential container should be made available in a new instance of `AnyExistentialContainer`
    init(_ instance: Any) {
        // TODO: If Swift implements support for static/compile-time assertions, we should adopt those here.

        // We require that `AnyExistentialContainer` and `Any` have the same memory layouts.
        assert(MemoryLayout<AnyExistentialContainer>.size == MemoryLayout<Any>.size)
        assert(MemoryLayout<AnyExistentialContainer>.alignment == MemoryLayout<Any>.alignment)
        assert(MemoryLayout<AnyExistentialContainer>.stride == MemoryLayout<Any>.stride)

        // Ensure that we catch any changes to the struct layout which might move it out of alignment with `Any`.
        // Importantly, `fixedSizeBuffer` should be at offset 0, `fixedSizeBuffer` should be exactly three words wide, and `type` should be at an offset immediately after `fixedSizeBuffer`.
        assert(MemoryLayout<AnyExistentialContainer>.offset(of: \AnyExistentialContainer.fixedSizeBuffer) == 0)
        assert(MemoryLayout<(UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?)>.size == (3 * MemoryLayout<UnsafeRawPointer?>.size))
        assert(MemoryLayout<AnyExistentialContainer>.offset(of: \AnyExistentialContainer.type) == MemoryLayout<(UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?)>.size)

        // We also require that `Any.Type?` be a trivial type so that it's safe to load this way.
        assert(_isPOD(Any.Type?.self))

        // Finally, we require that we are a trivial type as well.
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
///   - If the instance conforms to `CustomStringConvertible`, use `String(describing:)` to call `.description` directly
///   - If the instance conforms to `CustomDebugStringConvertible` (but NOT `CustomStringConvertible`), use `String(reflecting:)`
///   - If the instance is an enum (as reported using Mirror), use `String(describing:)`
///   - Otherwise, use the normalized type name
fileprivate func generateSummary(for instance: Any, withTypeName typeNameProvider: @autoclosure () -> String, using mirrorProvider: @autoclosure () -> Mirror) -> String {
    if let string = instance as? String {
        return string
    }

    // Use String(describing:) for CustomStringConvertible so that .description is used directly,
    // without the debug decoration (e.g. surrounding quotes) added by String(reflecting:).
    if instance is CustomStringConvertible {
        return String(describing: instance)
    }

    // Only fall back to String(reflecting:) for types that are solely CustomDebugStringConvertible.
    if instance is CustomDebugStringConvertible {
        return String(reflecting: instance)
    }

    let mirror = mirrorProvider()
    if mirror.displayStyle == .enum {
        return String(describing: instance)
    }

    return typeNameProvider()
}
