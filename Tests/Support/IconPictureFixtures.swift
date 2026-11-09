import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures a test writes into a Plugin package to declare as icons.
public enum IconPictureFixtures {
    /// A PNG or JPEG of `width` by `height` pixels, the left half filled.
    public static func bitmap(width: Int, height: Int, type: UTType = .png) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A one-page PDF of `width` by `height` points whose left half is a
    /// filled vector rectangle, so a sharp edge runs down its middle.
    public static func pdf(width: Double = 32, height: Double = 32) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Describes a package file the way the conformance fixtures do:
    /// `{"png": [w, h]}`, `{"jpeg": [w, h]}`, `{"pdf": [w, h]}` or
    /// `{"bytes": n}` (n zero bytes).
    public static func file(described description: [String: Any]) -> Data {
        if let size = description["png"] as? [Int] { return bitmap(width: size[0], height: size[1]) }
        if let size = description["jpeg"] as? [Int] { return bitmap(width: size[0], height: size[1], type: .jpeg) }
        if let size = description["pdf"] as? [Double] { return pdf(width: size[0], height: size[1]) }
        if let count = description["bytes"] as? Int { return Data(count: count) }
        preconditionFailure("unknown package file description \(description)")
    }
}
