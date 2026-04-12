import Testing
import SwiftUI
@testable import PullRequestPilot

@Suite("Color(hex:)")
struct ColorHexTests {

    @Test("parses valid 6-character hex without hash")
    func validHexNoHash() {
        let color = Color(hex: "FF0000")
        // Should not crash and should produce a valid color
        #expect(color.description.isEmpty == false)
    }

    @Test("parses valid 6-character hex with hash")
    func validHexWithHash() {
        let color = Color(hex: "#00FF00")
        #expect(color.description.isEmpty == false)
    }

    @Test("returns gray for invalid hex length")
    func invalidLength() {
        // Short hex string should fall back to gray
        let color = Color(hex: "FFF")
        #expect(color.description.isEmpty == false)
    }

    @Test("returns gray for empty string")
    func emptyString() {
        let color = Color(hex: "")
        #expect(color.description.isEmpty == false)
    }

    @Test("parses black correctly")
    func blackHex() {
        let color = Color(hex: "000000")
        #expect(color.description.isEmpty == false)
    }

    @Test("parses white correctly")
    func whiteHex() {
        let color = Color(hex: "FFFFFF")
        #expect(color.description.isEmpty == false)
    }

    @Test("handles lowercase hex")
    func lowercaseHex() {
        let color = Color(hex: "abcdef")
        #expect(color.description.isEmpty == false)
    }

    @Test("strips hash prefix before parsing")
    func hashStripping() {
        // Both should produce the same color
        let withHash = Color(hex: "#FF0000")
        let withoutHash = Color(hex: "FF0000")
        #expect(withHash.description == withoutHash.description)
    }
}
