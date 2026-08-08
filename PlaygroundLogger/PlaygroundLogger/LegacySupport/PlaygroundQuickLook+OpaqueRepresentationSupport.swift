//===--- PlaygroundQuickLook+OpaqueRepresentationSupport.swift ------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

#if os(iOS) || os(tvOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

extension _PlaygroundQuickLook {
    func opaqueRepresentation() throws -> LogEntry.OpaqueRepresentation {
        // TODO: don't crash in this function; instead, throw an error so we can encode an error log message instead
        
        switch self {
        case let .text(text):
            return text
        case let .int(int):
            return int
        case let .uInt(uInt):
            return uInt
        case let .float(float):
            return float
        case let .double(double):
            return double
        case let .image(imageObject):
            #if os(macOS)
                guard let image = imageObject as? NSImage else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Image is not an NSImage; it is '\(type(of: imageObject))' instead")
                }
                
                return ImageOpaqueRepresentation(kind: .image, backedBy: image)
            #elseif os(iOS) || os(tvOS)
                guard let image = imageObject as? UIImage else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Image is not a UIImage; it is '\(type(of: imageObject))' instead")
                }
                
                return ImageOpaqueRepresentation(kind: .image, backedBy: image)
                
            #endif
        case .sound:
            throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Sounds are not supported")
        case let .color(colorObject):
            #if os(macOS)
                guard let color = colorObject as? NSColor else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Color is not an NSColor; it is '\(type(of: colorObject))' instead")
                }
                
                return color.cgColor
            #elseif os(iOS) || os(tvOS)
                guard let color = colorObject as? UIColor else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Color is not a UIColor; it is '\(type(of: colorObject))' instead")
                }
                
                return color.cgColor
            #endif
        case let .bezierPath(bezierPathObject):
            #if os(macOS)
                guard let bezierPath = bezierPathObject as? NSBezierPath else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Bezier path is not an NSBezierPath; it is '\(type(of: bezierPathObject))' instead")
                }
                
                return bezierPath
            #elseif os(iOS) || os(tvOS)
                guard let bezierPath = bezierPathObject as? UIBezierPath else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Bezier path is not a UIBezierPath; it is '\(type(of: bezierPathObject))' instead")
                }
                
                return bezierPath
            #endif
        case let .attributedString(attributedStringObject):
            guard let attributedString = attributedStringObject as? NSAttributedString else {
                throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Attributed string is not an NSAttributedString; it is '\(type(of: attributedStringObject))' instead")
            }
            
            return attributedString
        case let .rectangle(x, y, width, height):
            return CGRect(x: x, y: y, width: width, height: height)
        case let .point(x, y):
            return CGPoint(x: x, y: y)
        case let .size(width, height):
            return CGSize(width: width, height: height)
        case let .bool(bool):
            return bool
        case let .range(location, length):
            return NSRange(location: Int(location), length: Int(length))
        case let .view(viewOrImage):
            #if os(macOS)
                if let view = viewOrImage as? NSView {
                    return ImageOpaqueRepresentation(kind: .view, backedBy: view)
                }
                else if let image = viewOrImage as? NSImage {
                    return ImageOpaqueRepresentation(kind: .view, backedBy: image)
                }
                else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "View is not an NSView or NSImage; it is '\(type(of: viewOrImage))' instead")
                }
            #elseif os(iOS) || os(tvOS)
                if let view = viewOrImage as? UIView {
                    return ImageOpaqueRepresentation(kind: .view, backedBy: view)
                }
                else if let image = viewOrImage as? UIImage {
                    return ImageOpaqueRepresentation(kind: .view, backedBy: image)
                }
                else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "View is not a UIView or UIImage; it is '\(type(of: viewOrImage))' instead")
                }
            #endif
        case let .sprite(imageObject):
            // TODO: figure out if this is even a little bit right. (The previous implementation just logged a string for sprites?)
            #if os(macOS)
                guard let image = imageObject as? NSImage else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Sprite is not an NSImage; it is '\(type(of: imageObject))' instead")
                }
                
                return ImageOpaqueRepresentation(kind: .sprite, backedBy: image)
            #elseif os(iOS) || os(tvOS)
                guard let image = imageObject as? UIImage else {
                    throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "Sprite is not a UIImage; it is '\(type(of: imageObject))' instead")
                }
                
                return ImageOpaqueRepresentation(kind: .sprite, backedBy: image)
            #endif
        case let .url(urlString):
            guard let url = URL(string: urlString) else {
                throw LoggingError.failedToGenerateOpaqueRepresentation(reason: "String is not a valid URL string")
            }
            
            return url
        case let ._raw(bytes, tag):
            struct RawOpaqueRepresentation: TaggedOpaqueRepresentation {
                var tag: String
                var bytes: [UInt8]
                
                func encodePayload(into encoder: LogEncoder, usingFormat format: LogEncoder.Format) {
                    encoder.encode(number: UInt64(bytes.count))
                    encoder.encode(bytes: bytes, length: bytes.count)
                }
            }
            
            return RawOpaqueRepresentation(tag: tag, bytes: bytes)
        }
    }
}
