import Darwin
import WebKit
import XCTest
@testable import Lilo

/// Web Serial end to end against a pseudo-terminal standing in for the device.
@MainActor
final class SerialBridgeTests: XCTestCase {
    private var master: Int32 = -1
    private var slave: Int32 = -1

    override func tearDown() {
        if master >= 0 { close(master) }
        if slave >= 0 { close(slave) }
        super.tearDown()
    }

    /// A page whose picker grants the device at `devicePath`, or declines when it is nil.
    private func makeWebView(devicePath: String?) async -> WKWebView {
        let bridge = SerialBridge()
        bridge.listDevices = { devicePath.map { [SerialBridge.Device(path: $0, name: "Probe", usbVendorId: 0x2341, usbProductId: 0x43)] } ?? [] }
        bridge.chooseDevice = { devices, _, _ in devices.first }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: SerialBridge.messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: SerialBridge.polyfillSource, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>serial</p>", baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }
        return webView
    }

    func testAPagePicksAPortAndExchangesBytesWithIt() async throws {
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        let path = String(cString: ttyname(slave))
        let webView = await makeWebView(devicePath: path)

        let info = try await webView.callAsyncJavaScript("""
            window.received = '';
            const port = await navigator.serial.requestPort({ filters: [{ usbVendorId: 0x2341 }] });
            await port.open({ baudRate: 115200 });
            const writer = port.writable.getWriter();
            await writer.write(new TextEncoder().encode('hello'));
            writer.releaseLock();
            window.port = port;
            window.reader = port.readable.getReader();
            (async () => {
                for (;;) {
                    const { value, done } = await window.reader.read();
                    if (done) break;
                    window.received += new TextDecoder().decode(value);
                }
            })();
            return port.getInfo();
            """, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(info?["usbVendorId"] as? Int, 0x2341)

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(master, &buffer, buffer.count)
        XCTAssertEqual(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self), "hello")

        _ = "world".withCString { write(master, $0, 5) }
        let delivered = await pollUntil(timeout: 5) {
            (try? await webView.evaluateJavaScript("window.received")) as? String == "world"
        }
        XCTAssertTrue(delivered, "bytes from the device reach the page's reader")

        let reopenable = try await webView.callAsyncJavaScript("""
            await window.port.close();
            await window.port.open({ baudRate: 9600 });
            await window.port.close();
            return (await navigator.serial.getPorts()).length;
            """, contentWorld: .page) as? Int
        XCTAssertEqual(reopenable, 1, "a closed port opens again and stays granted")
    }

    func testDecliningThePickerRejectsWithNotFoundError() async throws {
        let webView = await makeWebView(devicePath: nil)

        let name = try await webView.callAsyncJavaScript("""
            try { await navigator.serial.requestPort(); return 'resolved'; } catch (e) { return e.name; }
            """, contentWorld: .page) as? String
        XCTAssertEqual(name, "NotFoundError")
    }
}
