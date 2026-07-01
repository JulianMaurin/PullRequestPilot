import AppKit
import Testing
import SwiftUI
@testable import PullRequestPilot

@Suite("Color(hex:)")
struct ColorHexTests {

    /// Resolves a SwiftUI Color to its sRGB components for assertion.
    private func sRGBComponents(_ color: Color) -> (r: Double, g: Double, b: Double)? {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (Double(nsColor.redComponent), Double(nsColor.greenComponent), Double(nsColor.blueComponent))
    }

    @Test("parses valid 6-character hex without hash")
    func validHexNoHash() throws {
        let color = Color(hex: "FF0000")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 1.0) < 0.01)
        #expect(abs(c.g - 0.0) < 0.01)
        #expect(abs(c.b - 0.0) < 0.01)
    }

    @Test("parses valid 6-character hex with hash")
    func validHexWithHash() throws {
        let color = Color(hex: "#00FF00")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 0.0) < 0.01)
        #expect(abs(c.g - 1.0) < 0.01)
        #expect(abs(c.b - 0.0) < 0.01)
    }

    @Test("returns gray for invalid hex length")
    func invalidLength() throws {
        let color = Color(hex: "FFF")
        let c = try #require(sRGBComponents(color))
        // Falls back to gray (0.5, 0.5, 0.5)
        #expect(abs(c.r - 0.5) < 0.01)
        #expect(abs(c.g - 0.5) < 0.01)
        #expect(abs(c.b - 0.5) < 0.01)
    }

    @Test("returns gray for empty string")
    func emptyString() throws {
        let color = Color(hex: "")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 0.5) < 0.01)
        #expect(abs(c.g - 0.5) < 0.01)
        #expect(abs(c.b - 0.5) < 0.01)
    }

    @Test("parses black correctly")
    func blackHex() throws {
        let color = Color(hex: "000000")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 0.0) < 0.01)
        #expect(abs(c.g - 0.0) < 0.01)
        #expect(abs(c.b - 0.0) < 0.01)
    }

    @Test("parses white correctly")
    func whiteHex() throws {
        let color = Color(hex: "FFFFFF")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 1.0) < 0.01)
        #expect(abs(c.g - 1.0) < 0.01)
        #expect(abs(c.b - 1.0) < 0.01)
    }

    @Test("handles lowercase hex")
    func lowercaseHex() throws {
        let color = Color(hex: "abcdef")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 0xAB / 255.0) < 0.01)
        #expect(abs(c.g - 0xCD / 255.0) < 0.01)
        #expect(abs(c.b - 0xEF / 255.0) < 0.01)
    }

    @Test("returns gray for 6-character non-hex string")
    func nonHexCharacters() throws {
        let color = Color(hex: "zzzzzz")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 0.5) < 0.01)
        #expect(abs(c.g - 0.5) < 0.01)
        #expect(abs(c.b - 0.5) < 0.01)
    }

    @Test("returns gray for partially-hex string")
    func partiallyHexCharacters() throws {
        let color = Color(hex: "12345Z")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 0.5) < 0.01)
        #expect(abs(c.g - 0.5) < 0.01)
        #expect(abs(c.b - 0.5) < 0.01)
    }

    @Test("parses lowercase hex with hash as red")
    func lowercaseRedWithHash() throws {
        let color = Color(hex: "#ff0000")
        let c = try #require(sRGBComponents(color))
        #expect(abs(c.r - 1.0) < 0.01)
        #expect(abs(c.g - 0.0) < 0.01)
        #expect(abs(c.b - 0.0) < 0.01)
    }

    @Test("strips hash prefix before parsing")
    func hashStripping() throws {
        let withHash = Color(hex: "#FF0000")
        let withoutHash = Color(hex: "FF0000")
        let c1 = try #require(sRGBComponents(withHash))
        let c2 = try #require(sRGBComponents(withoutHash))
        #expect(abs(c1.r - c2.r) < 0.001)
        #expect(abs(c1.g - c2.g) < 0.001)
        #expect(abs(c1.b - c2.b) < 0.001)
    }
}
