import XCTest
@testable import Lilo

final class TerminalThemeTests: XCTestCase {
    private let accent = VTColor(hex: 0x0A84FF)

    func testAutoPaletteStaysReadableOnLightAndDarkSpaces() {
        for surface in [VTColor(hex: 0xFAFAFA), VTColor(hex: 0xF2E8C9), VTColor(hex: 0x1E1E1E), VTColor(hex: 0x2B3A55)] {
            let colors = TerminalTheme.auto.resolved(surface: surface, accent: accent)

            XCTAssertEqual(colors.background, surface)
            XCTAssertGreaterThanOrEqual(colors.foreground.contrast(with: surface), 7, "text on \(surface.hexString)")
            for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
                XCTAssertGreaterThanOrEqual(colors.palette[index].contrast(with: surface), 4.5, "color \(index) on \(surface.hexString)")
            }
            for index in [0, 7, 8] {
                XCTAssertGreaterThanOrEqual(colors.palette[index].contrast(with: surface), 3, "color \(index) on \(surface.hexString)")
            }
        }
    }

    func testPresetsKeepTheirOwnColors() {
        XCTAssertEqual(Set(TerminalTheme.presets.map(\.id)).count, TerminalTheme.presets.count)
        for preset in TerminalTheme.presets {
            XCTAssertEqual(preset.palette.count, 16, preset.name)
            let colors = preset.resolved(surface: VTColor(hex: 0x123456), accent: accent)
            XCTAssertEqual(colors.background, preset.background, "a preset ignores the Space color")
            XCTAssertEqual(colors.palette, preset.palette)
        }
    }

    func testVSCodeThemeFileIsParsedOverItsInclude() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hues = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let ansi = (hues.map { "terminal.ansi\($0)" } + hues.map { "terminal.ansiBright\($0)" }).enumerated()
            .map { "\"\($1)\": \"#0000\(String(format: "%02x", $0))\"" }.joined(separator: ",\n")
        try """
        { "colors": { "editor.background": "#ffffff", "editor.foreground": "#123", \(ansi) } }
        """.write(to: folder.appendingPathComponent("base.json"), atomically: true, encoding: .utf8)
        try """
        {
            // A comment, and a trailing comma below.
            "include": "./base.json",
            "colors": {
                "editor.background": "#1e1e2e",
                "terminal.selectionBackground": "#ffffff80",
            },
        }
        """.write(to: folder.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)

        let colors = try XCTUnwrap(TerminalTheme.vscodeColors(at: folder.appendingPathComponent("theme.json")))
        let theme = try XCTUnwrap(TerminalTheme.vscode(colors, id: "x", name: "Example"))

        XCTAssertEqual(theme.background, VTColor(hex: 0x1E1E2E))
        XCTAssertEqual(theme.foreground, VTColor(hex: 0x112233))
        XCTAssertEqual(theme.selection, VTColor(hex: 0x1E1E2E).mixed(with: VTColor(hex: 0xFFFFFF), amount: 128.0 / 255))
        XCTAssertEqual(theme.palette.count, 16)
        XCTAssertEqual(theme.palette[15], VTColor(hex: 0x00000F))
        XCTAssertNil(TerminalTheme.vscode(["editorWidget.border": "#ffffff"], id: "y", name: "Nothing for a terminal"))
    }

    func testGhosttyThemeFileIsParsed() throws {
        let text = """
        # Example theme
        background = #1e1e2e
        foreground = cdd6f4
        cursor-color = #f5e0dc
        selection-background = "#585b70"
        """ + "\n" + (0..<16).map { "palette = \($0)=#0000\(String(format: "%02x", $0))" }.joined(separator: "\n")

        let theme = try XCTUnwrap(TerminalTheme.ghostty(text, id: "x", name: "Example"))

        XCTAssertEqual(theme.background, VTColor(hex: 0x1E1E2E))
        XCTAssertEqual(theme.foreground, VTColor(hex: 0xCDD6F4))
        XCTAssertEqual(theme.selection, VTColor(hex: 0x585B70))
        XCTAssertEqual(theme.palette.count, 16)
        XCTAssertEqual(theme.palette[15], VTColor(hex: 0x00000F))
        XCTAssertNil(TerminalTheme.ghostty("font-size = 14\n", id: "y", name: "Fonts only"))
    }

    func testITermColorPresetIsParsed() throws {
        func component(_ value: Double) -> [String: Any] {
            ["Red Component": value, "Green Component": value / 2, "Blue Component": 0.0]
        }
        var plist: [String: Any] = ["Background Color": component(0.1), "Foreground Color": component(0.9)]
        for index in 0..<16 { plist["Ansi \(index) Color"] = component(Double(index) / 15) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let theme = try XCTUnwrap(TerminalTheme.iTerm(data, id: "i", name: "Imported"))

        XCTAssertEqual(theme.palette.count, 16)
        XCTAssertEqual(theme.palette[15], VTColor(r: 255, g: 128, b: 0))
        XCTAssertEqual(theme.background, VTColor(r: 26, g: 13, b: 0))
    }

    func testITermComponentsOutOfRangeAreClamped() throws {
        let color: [String: Any] = ["Red Component": 1.2, "Green Component": -0.1, "Blue Component": 0.5]
        var plist: [String: Any] = [:]
        for index in 0..<16 { plist["Ansi \(index) Color"] = color }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let theme = try XCTUnwrap(TerminalTheme.iTerm(data, id: "i", name: "Extended"))

        XCTAssertEqual(theme.palette[0], VTColor(r: 255, g: 0, b: 128))
    }

    func testImportedThemesSurviveTheirJSONRoundTrip() throws {
        let theme = TerminalTheme.presets[0]

        let data = try JSONEncoder().encode([theme])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#1E1E2E"), "colors are stored as #rrggbb")
        XCTAssertEqual(try JSONDecoder().decode([TerminalTheme].self, from: data), [theme])
    }

    @MainActor
    func testHostAppliesAThemeToOpenTerminals() throws {
        let host = TerminalHost()
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        let view = try XCTUnwrap(host.ensureView(for: tab))
        defer { host.terminate(tab.id) }
        let dracula = try XCTUnwrap(TerminalTheme.presets.first { $0.id == "dracula" })

        host.setAppearance(TerminalHost.Appearance(theme: dracula, fontFamily: nil, fontSize: 13))

        let state = VTRenderState()
        view.session.withLockedTerminal { state.beginUpdate(from: $0) }
        state.endUpdate()
        XCTAssertEqual(state.colors.background, dracula.background)
        XCTAssertEqual(state.colors.foreground, dracula.foreground)
    }
}
