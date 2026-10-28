import AppKit

/// Terminal colors. Any color left nil is derived from Lilo: the Space's content surface for the
/// background, the accent color for cursor and selection, and a palette tuned for contrast.
struct TerminalTheme: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var background: VTColor?
    var foreground: VTColor?
    var cursor: VTColor?
    var selection: VTColor?
    /// The 16 ANSI colors; empty means generated for the background.
    var palette: [VTColor] = []

    /// Concrete colors for one terminal.
    struct Resolved: Equatable {
        var background: VTColor
        var foreground: VTColor
        var cursor: VTColor
        var selection: VTColor
        var match: VTColor
        var palette: [VTColor]
    }

    static let auto = TerminalTheme(id: "auto", name: "Lilo")

    func resolved(surface: VTColor, accent: VTColor) -> Resolved {
        let background = background ?? surface
        let dark = background.luminance < 0.4
        let foreground = foreground ?? (dark ? VTColor(hex: 0xE6E6E6) : VTColor(hex: 0x1D1D1F))
        let palette = palette.count == 16 ? palette : Self.readablePalette(on: background, dark: dark)
        return Resolved(
            background: background,
            foreground: foreground,
            cursor: cursor ?? accent,
            selection: selection ?? accent.mixed(with: background, amount: 0.55),
            // Matches stand apart from both the text and the current match (the selection).
            match: palette[3].mixed(with: background, amount: 0.62),
            palette: palette
        )
    }

    /// Lilo's own palette, each color nudged until it reads well on `background`.
    private static func readablePalette(on background: VTColor, dark: Bool) -> [VTColor] {
        let base: [UInt32] = dark
            ? [0x2C2C2E, 0xFF6B6B, 0x7BD88F, 0xF4C56A, 0x6CB6FF, 0xC98BFF, 0x5FD7D7, 0xD4D4D4,
               0x7A7A80, 0xFF8787, 0x9BE7A8, 0xFFD78A, 0x91C8FF, 0xDCAAFF, 0x8BE9E9, 0xF5F5F5]
            : [0x1D1D1F, 0xC62828, 0x2E7D32, 0x8D6E00, 0x1565C0, 0x8E24AA, 0x00796B, 0x9E9E9E,
               0x616161, 0xE53935, 0x43A047, 0xA67C00, 0x1E88E5, 0xAB47BC, 0x00897B, 0xBDBDBD]
        return base.enumerated().map { index, hex in
            let color = VTColor(hex: hex)
            // Black, white and gray mostly frame or dim things, so on dark they only need to stay visible;
            // bright white is often a background and keeps its color.
            switch index {
            case 15: return color
            case 0, 7, 8: return color.ensuringContrast(dark ? 3 : 4.5, on: background)
            default: return color.ensuringContrast(4.5, on: background)
            }
        }
    }

    // MARK: - Presets

    static let presets: [TerminalTheme] = [
        preset("catppuccin-mocha", "Catppuccin Mocha", 0x1E1E2E, 0xCDD6F4, 0xF5E0DC, 0x585B70, [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8
        ]),
        preset("catppuccin-latte", "Catppuccin Latte", 0xEFF1F5, 0x4C4F69, 0xDC8A78, 0xACB0BE, [
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC
        ]),
        preset("tokyo-night", "Tokyo Night", 0x1A1B26, 0xC0CAF5, 0xC0CAF5, 0x33467C, [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5
        ]),
        preset("dracula", "Dracula", 0x282A36, 0xF8F8F2, 0xF8F8F2, 0x44475A, [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
        ]),
        preset("solarized-dark", "Solarized Dark", 0x002B36, 0x839496, 0x93A1A1, 0x073642, solarized),
        preset("solarized-light", "Solarized Light", 0xFDF6E3, 0x657B83, 0x586E75, 0xEEE8D5, solarized),
        preset("gruvbox-dark", "Gruvbox Dark", 0x282828, 0xEBDBB2, 0xEBDBB2, 0x504945, [
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2
        ]),
        preset("nord", "Nord", 0x2E3440, 0xD8DEE9, 0xD8DEE9, 0x434C5E, [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4
        ]),
        preset("one-dark", "One Dark", 0x282C34, 0xABB2BF, 0x528BFF, 0x3E4451, [
            0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF
        ]),
        preset("github-light", "GitHub Light", 0xFFFFFF, 0x1F2328, 0x0969DA, 0xB6E3FF, [
            0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F
        ])
    ]

    private static let solarized: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
    ]

    private static func preset(_ id: String, _ name: String, _ background: UInt32, _ foreground: UInt32,
                               _ cursor: UInt32, _ selection: UInt32, _ palette: [UInt32]) -> TerminalTheme {
        TerminalTheme(
            id: id, name: name, background: VTColor(hex: background), foreground: VTColor(hex: foreground),
            cursor: VTColor(hex: cursor), selection: VTColor(hex: selection), palette: palette.map(VTColor.init(hex:))
        )
    }

    // MARK: - Import

    /// A Ghostty theme or config: `palette = N=#rrggbb`, `background`, `foreground`, `cursor-color`,
    /// `selection-background`. Nil when the text sets no color at all.
    static func ghostty(_ text: String, id: String, name: String) -> TerminalTheme? {
        var theme = TerminalTheme(id: id, name: name)
        var palette: [VTColor?] = Array(repeating: nil, count: 16)
        for (key, value) in ghosttyEntries(text) {
            switch key {
            case "background": theme.background = VTColor(hexString: value)
            case "foreground": theme.foreground = VTColor(hexString: value)
            case "cursor-color": theme.cursor = VTColor(hexString: value)
            case "selection-background": theme.selection = VTColor(hexString: value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index) {
                    palette[index] = VTColor(hexString: parts[1])
                }
            default: break
            }
        }
        if palette.allSatisfy({ $0 != nil }) { theme.palette = palette.compactMap { $0 } }
        let setsAnything = theme.background != nil || theme.foreground != nil || !theme.palette.isEmpty
        return setsAnything ? theme : nil
    }

    /// `key = value` lines of a Ghostty file, comments and blank lines skipped.
    static func ghosttyEntries(_ text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { return nil }
            let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return key.isEmpty ? nil : (key, value)
        }
    }

    /// An iTerm2 `.itermcolors` property list.
    static func iTerm(_ data: Data, id: String, name: String) -> TerminalTheme? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func color(_ key: String) -> VTColor? {
            guard let entry = plist[key] as? [String: Any],
                  let red = entry["Red Component"] as? Double,
                  let green = entry["Green Component"] as? Double,
                  let blue = entry["Blue Component"] as? Double else { return nil }
            // Presets saved in an extended color space hold components past 0...1, which UInt8 would trap on.
            func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
            return VTColor(r: byte(red), g: byte(green), b: byte(blue))
        }
        let palette = (0..<16).compactMap { color("Ansi \($0) Color") }
        guard palette.count == 16 else { return nil }
        return TerminalTheme(
            id: id, name: name, background: color("Background Color"), foreground: color("Foreground Color"),
            cursor: color("Cursor Color"), selection: color("Selection Color"), palette: palette
        )
    }

    /// The `colors` of a VS Code color theme file (JSON with comments), over those of the theme it includes.
    static func vscodeColors(at url: URL, depth: Int = 0) -> [String: String]? {
        guard depth < 8, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else { return nil }
        var colors: [String: String] = [:]
        if let include = json["include"] as? String {
            colors = vscodeColors(at: URL(fileURLWithPath: include, relativeTo: url.deletingLastPathComponent()), depth: depth + 1) ?? [:]
        }
        colors.merge((json["colors"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }) { $1 }
        return colors
    }

    /// VS Code workbench colors: the terminal's own, else the editor's. Nil when they set no color at all.
    static func vscode(_ colors: [String: String], id: String, name: String) -> TerminalTheme? {
        // `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`; a translucent color is flattened onto `base`.
        func color(_ keys: String..., over base: VTColor?) -> VTColor? {
            guard var digits = keys.lazy.compactMap({ colors[$0] }).first else { return nil }
            if digits.hasPrefix("#") { digits.removeFirst() }
            if digits.count == 3 || digits.count == 4 { digits = String(digits.flatMap { [$0, $0] }) }
            guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
            guard digits.count == 8 else { return VTColor(hex: value) }
            let opaque = VTColor(hex: value >> 8)
            return base.map { opaque.mixed(with: $0, amount: 1 - Double(value & 0xFF) / 255) } ?? opaque
        }
        let background = color("terminal.background", "editor.background", over: nil)
        let hues = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let palette = (hues.map { "terminal.ansi\($0)" } + hues.map { "terminal.ansiBright\($0)" })
            .compactMap { color($0, over: background) }
        let theme = TerminalTheme(
            id: id, name: name, background: background,
            foreground: color("terminal.foreground", "editor.foreground", over: background),
            cursor: color("terminalCursor.foreground", "editorCursor.foreground", over: background),
            selection: color("terminal.selectionBackground", "editor.selectionBackground", over: background),
            palette: palette.count == 16 ? palette : []
        )
        return theme.background != nil || theme.foreground != nil || !theme.palette.isEmpty ? theme : nil
    }
}

extension VTColor: Codable {
    init(hex: UInt32) {
        self.init(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF))
    }

    /// `#rrggbb` or `rrggbb`.
    init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }

    init(_ color: NSColor) {
        // An extended-range color holds components past 0...1, which UInt8 would trap on.
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor.black
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(r: byte(rgb.redComponent), g: byte(rgb.greenComponent), b: byte(rgb.blueComponent))
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = VTColor(hexString: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a #rrggbb color: \(text)"))
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    func contrast(with other: VTColor) -> Double {
        let (light, dark) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (light + 0.05) / (dark + 0.05)
    }

    func mixed(with other: VTColor, amount: Double) -> VTColor {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - amount) + Double(b) * amount).rounded()) }
        return VTColor(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }

    /// Steps toward black or white, whichever the background is farther from, until the contrast
    /// target is met; the hue stays recognizable.
    func ensuringContrast(_ target: Double, on background: VTColor) -> VTColor {
        let towards = background.luminance > 0.4 ? VTColor(r: 0, g: 0, b: 0) : VTColor(r: 255, g: 255, b: 255)
        var color = self
        var step = 0.0
        while color.contrast(with: background) < target, step < 1 {
            step += 0.05
            color = mixed(with: towards, amount: step)
        }
        return color
    }
}

extension TerminalTheme {
    /// What the user's Ghostty config sets, so a Ghostty user feels at home.
    struct GhosttyConfig: Equatable {
        var theme: TerminalTheme?
        var themeName: String?
        var fontFamily: String?
        var fontSize: CGFloat?
    }

    /// Reads `~/.config/ghostty/config` (or Ghostty's Application Support copy). Nil without Ghostty.
    static func ghosttyConfig(dark: Bool) -> GhosttyConfig? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let texts = [".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config"]
            .compactMap { try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8) }
        guard !texts.isEmpty else { return nil }
        let text = texts.joined(separator: "\n")
        var config = GhosttyConfig()
        for (key, value) in ghosttyEntries(text) {
            switch key {
            case "theme": config.themeName = value
            // The first font-family is the primary one; later lines add fallbacks.
            case "font-family": if config.fontFamily == nil, !value.isEmpty { config.fontFamily = value }
            case "font-size": config.fontSize = Double(value).map { CGFloat($0) }
            default: break
            }
        }
        if let spec = config.themeName {
            // "light:Name,dark:Name" follows the system appearance.
            let name = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(dark ? "dark:" : "light:") }
                .map { String($0.drop { $0 != ":" }.dropFirst()) } ?? spec
            config.themeName = name
            let candidates = name.hasPrefix("/") ? [URL(fileURLWithPath: name)] : [
                home.appendingPathComponent(".config/ghostty/themes/\(name)"),
                URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)")
            ]
            config.theme = candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
                .flatMap { ghostty($0, id: "ghostty", name: "Ghostty") }
        }
        // Colors set directly in the config win over the named theme's.
        if let explicit = ghostty(text, id: "ghostty", name: "Ghostty") {
            var theme = config.theme ?? explicit
            theme.background = explicit.background ?? theme.background
            theme.foreground = explicit.foreground ?? theme.foreground
            theme.cursor = explicit.cursor ?? theme.cursor
            theme.selection = explicit.selection ?? theme.selection
            if !explicit.palette.isEmpty { theme.palette = explicit.palette }
            config.theme = theme
        }
        return config
    }

    /// The color theme VS Code shows, with the user's color customizations. Nil without VS Code.
    static func vscodeTheme(dark: Bool) -> TerminalTheme? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: home.appendingPathComponent("Library/Application Support/Code/User/settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else { return nil }
        let name = (settings["window.autoDetectColorScheme"] as? Bool == true
            ? settings[dark ? "workbench.preferredDarkColorTheme" : "workbench.preferredLightColorTheme"]
            : settings["workbench.colorTheme"]) as? String ?? (dark ? "Dark Modern" : "Light Modern")
        let builtIn = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")?
            .appendingPathComponent("Contents/Resources/app/extensions")
        // Only a manifest that mentions the theme is worth parsing.
        let needle = Data((name.hasPrefix("Default ") ? String(name.dropFirst(8)) : name).utf8)
        let fileManager = FileManager.default
        var colors: [String: String]?
        search: for root in [home.appendingPathComponent(".vscode/extensions"), builtIn].compactMap({ $0 }) {
            for folder in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard let manifest = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
                      manifest.range(of: needle) != nil,
                      let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                      let themes = (json["contributes"] as? [String: Any])?["themes"] as? [[String: Any]] else { continue }
                for theme in themes {
                    guard let id = theme["id"] as? String ?? theme["label"] as? String, let path = theme["path"] as? String,
                          // Older VS Code settings name the built-in themes "Default Dark Modern" and the like.
                          id == name || "Default \(id)" == name else { continue }
                    colors = vscodeColors(at: folder.appendingPathComponent(path))
                    break search
                }
            }
        }
        guard var colors else { return nil }
        if let custom = settings["workbench.colorCustomizations"] as? [String: Any] {
            colors.merge(custom.compactMapValues { $0 as? String }) { $1 }
            // Customizations under "[Theme Name]" apply to that theme only.
            colors.merge((custom["[\(name)]"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }) { $1 }
        }
        return vscode(colors, id: "vscode", name: "VS Code (\(name))")
    }
}
