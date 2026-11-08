import AppKit

/// APCA 0.0.98G lightness contrast (absolute Lc) of 8-bit sRGB `text` on `background`: lilo-ui's `apcaContrast`.
func apcaContrast(text: (r: Double, g: Double, b: Double), background: (r: Double, g: Double, b: Double)) -> Double {
    func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        let y = 0.2126729 * pow(c.r / 255, 2.4) + 0.7151522 * pow(c.g / 255, 2.4) + 0.072175 * pow(c.b / 255, 2.4)
        return y > 0.022 ? y : y + pow(0.022 - y, 1.414)
    }
    let (t, b) = (luminance(text), luminance(background))
    let contrast = b > t ? (pow(b, 0.56) - pow(t, 0.57)) * 1.14 : (pow(b, 0.65) - pow(t, 0.62)) * 1.14
    return abs(contrast) < 0.1 ? 0 : (abs(contrast) - 0.027) * 100
}

/// Whether light text reads better than dark text on `color` by APCA: lilo-ui's `prefersLightText`.
func prefersLightText(_ color: (r: Double, g: Double, b: Double)) -> Bool {
    apcaContrast(text: (0xf8, 0xf9, 0xfd), background: color) >= apcaContrast(text: (0x1d, 0x1d, 0x1f), background: color)
}

extension NSColor {
    /// Parse a CSS hex color like "#e2daf1" or "#1a1a2e" into an NSColor.
    convenience init?(cssHex hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6 || h.count == 3 else { return nil }

        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }

        guard let value = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private var srgbColor: NSColor? {
        usingColorSpace(.sRGB)
    }

    private static let lightContrastColor = NSColor(cssHex: "#1d1d1f") ?? .textColor
    private static let darkContrastColor = NSColor(cssHex: "#f7f8fc") ?? .textColor

    var cssHexString: String? {
        guard let srgbColor else { return nil }

        func componentHex(_ value: CGFloat) -> String {
            let clampedValue = max(0, min(1, value))
            return unsafe String(format: "%02x", Int(round(clampedValue * 255.0)))
        }

        return "#\(componentHex(srgbColor.redComponent))\(componentHex(srgbColor.greenComponent))\(componentHex(srgbColor.blueComponent))"
    }

    /// The sidebar background for this Space color: `--sidebar-bg` from lilo-ui/src/lib/sidebarTheme.ts,
    /// in the same 8-bit steps so the window frame and the first frame match the page.
    func sidebarBackgroundColor(prefersDark: Bool) -> NSColor {
        guard let srgbColor else { return self }
        let source = SidebarRGB(srgbColor)
        guard prefersDark else { return source.color }
        let tinted = source.mixed(with: .darkCanvas, ratio: 0.58)
        var sidebar = tinted
        let accent = source.mixed(with: .white, ratio: 0.18)
        if sidebar.failsDarkRowContrast(accent: accent) {
            let (lightness, a, b) = source.oklab
            let (_, ta, tb) = tinted.oklab
            let scale = min(1, max(0.06, hypot(ta, tb)) / hypot(a, b))
            var step = 1
            while step <= 100 && sidebar.failsDarkRowContrast(accent: accent) {
                sidebar = SidebarRGB(oklabLightness: lightness - Double(step) / 100, a: a * scale, b: b * scale)
                step += 1
            }
        }
        return sidebar.color
    }

    /// Light text reads better on it, as the sidebar's text on the same color.
    var isPerceptuallyDark: Bool {
        guard let srgbColor else { return true }
        return prefersLightText(SidebarRGB(srgbColor).channels)
    }

    var contrastingForegroundColor: NSColor {
        isPerceptuallyDark ? Self.darkContrastColor : Self.lightContrastColor
    }

    /// Light themes lift the page area toward white; dark ones sink it below the sidebar, as Xcode and code editors do.
    var contentSurfaceColor: NSColor {
        (isPerceptuallyDark ? blended(withFraction: 0.25, of: .black) : blended(withFraction: 0.84, of: .white)) ?? self
    }

    var contentSurfaceBorderColor: NSColor {
        let surface = contentSurfaceColor
        return surface.blended(withFraction: 0.14, of: surface.contrastingForegroundColor)
            ?? surface.contrastingForegroundColor.withAlphaComponent(0.14)
    }
}

/// sidebarTheme.ts's RGB: 0 to 255 channels, every mix rounded to the next 8-bit value like the page's.
private struct SidebarRGB {
    var r: Double
    var g: Double
    var b: Double

    static let darkCanvas = SidebarRGB(r: 43, g: 47, b: 60)
    static let darkText = SidebarRGB(r: 0xf8, g: 0xf9, b: 0xfd)
    static let white = SidebarRGB(r: 255, g: 255, b: 255)
    static let black = SidebarRGB(r: 0, g: 0, b: 0)

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: NSColor) {
        r = (color.redComponent * 255).rounded()
        g = (color.greenComponent * 255).rounded()
        b = (color.blueComponent * 255).rounded()
    }

    /// `fromOklab`: each channel clamped to sRGB, then rounded to 8 bits.
    init(oklabLightness lightness: Double, a: Double, b: Double) {
        let l = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s = lightness - 0.0894841775 * a - 1.291485548 * b
        let (l3, m3, s3) = (l * l * l, m * m * m, s * s * s)
        func channel(_ linear: Double) -> Double {
            let v = max(0, min(1, linear))
            return ((v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255).rounded()
        }
        r = channel(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3)
        g = channel(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3)
        self.b = channel(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3)
    }

    var color: NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    var channels: (r: Double, g: Double, b: Double) {
        (r, g, b)
    }

    func mixed(with target: SidebarRGB, ratio: Double) -> SidebarRGB {
        blended(with: target, ratio: ratio).rounded
    }

    private func blended(with target: SidebarRGB, ratio: Double) -> SidebarRGB {
        SidebarRGB(r: r + (target.r - r) * ratio, g: g + (target.g - g) * ratio, b: b + (target.b - b) * ratio)
    }

    private var rounded: SidebarRGB {
        SidebarRGB(r: r.rounded(), g: g.rounded(), b: b.rounded())
    }

    private static func linearized(_ channel: Double) -> Double {
        let value = channel / 255
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// `toOklab`: OKLab with Bjorn Ottosson's matrices.
    var oklab: (lightness: Double, a: Double, b: Double) {
        let (lr, lg, lb) = (Self.linearized(r), Self.linearized(g), Self.linearized(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        )
    }

    /// APCA Lc of this color as text on `background`.
    private func contrast(on background: SidebarRGB) -> Double {
        apcaContrast(text: channels, background: background.channels)
    }

    /// `ensureContrast` at the icon threshold (Lc 45), as the page guards the accent on the sidebar.
    private func iconContrasted(on background: SidebarRGB) -> SidebarRGB {
        if contrast(on: background) >= 45 { return self }
        let target: SidebarRGB = Self.black.contrast(on: background) >= Self.white.contrast(on: background) ? .black : .white
        var step = 0.05
        while step <= 1.0001 {
            let candidate = mixed(with: target, ratio: step)
            if candidate.contrast(on: background) >= 45 { return candidate }
            step += 0.05
        }
        return .darkText
    }

    /// The pull-back test of `deriveSidebarThemeVariables` on a dark sidebar: light text under its `DARK_ROW_CONTRAST`
    /// (Lc 75) on a lifted row, or on that row tinted by the lightened Space color.
    func failsDarkRowContrast(accent: SidebarRGB) -> Bool {
        let selected = mixed(with: .darkText, ratio: 0.2)
        let activeTab = selected.blended(with: accent.iconContrasted(on: self), ratio: 0.18)
        return Self.darkText.contrast(on: activeTab) < 75
            || Self.darkText.contrast(on: mixed(with: .darkText, ratio: 0.28)) < 75
    }
}
