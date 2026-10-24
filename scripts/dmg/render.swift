// Renders background.html to background.png (640x400) and background@2x.png (1280x800) beside it.
// Usage: swift scripts/dmg/render.swift
import AppKit
import WebKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    var scales = [1, 2]

    override init() {
        super.init()
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
        web.loadFileURL(dir.appendingPathComponent("background.html"), allowingReadAccessTo: dir)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { snapshot() }

    func snapshot() {
        guard let scale = scales.first else { exit(0) }
        let config = WKSnapshotConfiguration()
        // snapshotWidth is in points: the bitmap comes out at the screen's backing scale.
        config.snapshotWidth = NSNumber(value: 640 * CGFloat(scale) / window.backingScaleFactor)
        web.takeSnapshot(with: config) { image, error in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: 640, height: 400)
            let name = scale == 1 ? "background.png" : "background@\(scale)x.png"
            try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            print("wrote \(name) \(cg.width)x\(cg.height)")
            self.scales.removeFirst()
            self.snapshot()
        }
    }
}

let renderer = Renderer()
app.run()
