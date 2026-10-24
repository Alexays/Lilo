import AppKit
import IOKit
import IOKit.serial
import WebKit

/// Web Serial (`navigator.serial`), which WebKit does not implement: a page-world polyfill backed by
/// the serial devices IOKit lists. A port only reaches an origin the user picked it for, and only a
/// secure top-level document can ask.
@MainActor
final class SerialBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloSerial"

    struct Device: Equatable {
        let path: String
        let name: String
        let usbVendorId: Int?
        let usbProductId: Int?
    }

    /// The devices to offer; IOKit's serial devices by default.
    var listDevices: () -> [Device] = SerialBridge.systemDevices
    /// Asks the user to pick one of `devices` for `host`; nil when they decline.
    var chooseDevice: (_ devices: [Device], _ host: String, _ webView: WKWebView) async -> Device? = SerialBridge.presentPicker

    /// Ports the user granted, by origin; they last for the session.
    private var granted: [String: Set<String>] = [:]

    /// An open port and the document that opened it: a reloaded or closed page loses its ports.
    private struct Owned {
        let connection: SerialConnection
        weak var webView: WKWebView?
        let document: String
    }
    private var connections: [String: Owned] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let frame = message.frameInfo
        guard frame.isMainFrame, frame.securityOrigin.isPotentiallyTrustworthy, let webView = message.webView,
              let body = message.body as? [String: Any], let action = body["action"] as? String else {
            return (nil, "SecurityError: Web Serial is only available to secure top-level pages")
        }
        let origin = frame.securityOrigin.permissionOriginKey
        let path = body["id"] as? String
        let document = body["document"] as? String ?? ""
        if let path, action != "requestPort", granted[origin]?.contains(path) != true {
            return (nil, "NotFoundError: The port is not available")
        }
        // Ports held by a page that has since reloaded or gone are released before anyone uses them.
        for (key, owned) in connections where owned.webView == nil || (owned.webView === webView && owned.document != document) {
            owned.connection.close()
            connections[key] = nil
        }
        let connection = path.flatMap { connections[$0] }.flatMap { $0.webView === webView ? $0.connection : nil }
        switch action {
        case "requestPort":
            let filters = body["filters"] as? [[String: Any]] ?? []
            let devices = listDevices().filter { device in
                filters.isEmpty || filters.contains { filter in
                    (filter["usbVendorId"] as? Int).map { $0 == device.usbVendorId } ?? true
                        && (filter["usbProductId"] as? Int).map { $0 == device.usbProductId } ?? true
                }
            }
            guard let device = await chooseDevice(devices, frame.securityOrigin.host, webView) else {
                return (nil, "NotFoundError: No port selected by the user")
            }
            granted[origin, default: []].insert(device.path)
            return (info(device), nil)
        case "getPorts":
            let paths = granted[origin] ?? []
            return (listDevices().filter { paths.contains($0.path) }.map(info), nil)
        case "forget":
            if let path {
                granted[origin]?.remove(path)
                connection?.close()
            }
            return (nil, nil)
        case "open":
            guard let path else { return (nil, "TypeError: Missing port") }
            guard connections[path] == nil else { return (nil, "InvalidStateError: The port is already open") }
            do {
                let connection = try SerialConnection(path: path, options: body)
                connection.onData = { [weak webView] data in
                    webView?.callAsyncJavaScript("window.__liloSerialData?.(id, data)",
                                                 arguments: ["id": path, "data": data.base64EncodedString()],
                                                 in: nil, in: .page, completionHandler: nil)
                }
                connection.onEnd = { [weak self, weak webView, weak connection] in
                    if self?.connections[path]?.connection === connection { self?.connections[path] = nil }
                    webView?.callAsyncJavaScript("window.__liloSerialEnd?.(id)", arguments: ["id": path],
                                                 in: nil, in: .page, completionHandler: nil)
                }
                connections[path] = Owned(connection: connection, webView: webView, document: document)
                connection.start()
                return (nil, nil)
            } catch {
                return (nil, "NetworkError: Failed to open serial port (\(error.localizedDescription))")
            }
        case "close":
            // Released at once, not when the descriptor closes on its queue: an open right after finds the port
            // free, and the reopened port hears no disconnect from the old connection's end.
            if let path, let connection {
                connection.onEnd = nil
                connections[path] = nil
                connection.close()
            }
            return (nil, nil)
        case "write":
            guard let connection else { return (nil, "InvalidStateError: The port is not open") }
            guard let data = (body["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return (nil, "TypeError: Bad data") }
            return await connection.write(data) ? (nil, nil) : (nil, "NetworkError: Failed to write to the port")
        case "setSignals":
            guard let connection else { return (nil, "InvalidStateError: The port is not open") }
            let set = await connection.setSignals(dataTerminalReady: body["dataTerminalReady"] as? Bool,
                                                  requestToSend: body["requestToSend"] as? Bool, breakOn: body["break"] as? Bool)
            return set ? (nil, nil) : (nil, "NetworkError: Failed to set signals")
        case "getSignals":
            guard let signals = await connection?.signals() else {
                return (nil, "InvalidStateError: The port is not open")
            }
            return (signals, nil)
        default:
            return (nil, "NotSupportedError: \(action)")
        }
    }

    private func info(_ device: Device) -> [String: Any] {
        var info: [String: Any] = ["id": device.path]
        if let vendor = device.usbVendorId { info["usbVendorId"] = vendor }
        if let product = device.usbProductId { info["usbProductId"] = product }
        return info
    }

    // MARK: - System devices and picker

    nonisolated static func systemDevices() -> [Device] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            func parentProperty(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let name = parentProperty("USB Product Name") as? String ?? parentProperty("kUSBProductString") as? String
            devices.append(Device(path: path, name: name ?? (path as NSString).lastPathComponent,
                                  usbVendorId: parentProperty("idVendor") as? Int, usbProductId: parentProperty("idProduct") as? Int))
        }
        return devices
    }

    static func presentPicker(devices: [Device], host: String, webView: WKWebView) async -> Device? {
        guard let window = webView.window else { return nil }
        let alert = NSAlert()
        alert.messageText = String(format: "%@ wants to connect to a serial port".localized, host)
        guard !devices.isEmpty else {
            alert.informativeText = "No compatible devices found.".localized
            alert.addButton(withTitle: "OK".localized)
            _ = await alert.beginSheetModal(for: window)
            return nil
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: devices.map { "\($0.name) (\(($0.path as NSString).lastPathComponent))" })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Connect".localized)
        alert.addButton(withTitle: "Cancel".localized)
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return devices[popup.indexOfSelectedItem]
    }
}

// MARK: - Connection

/// One open serial device: raw termios at the page's line settings, reads on a dispatch source, and
/// writes on their own queue so a slow device never blocks the main thread.
final class SerialConnection: @unchecked Sendable {
    enum Failure: LocalizedError {
        case open(Int32), configure(Int32)
        var errorDescription: String? {
            switch self {
            case let .open(code), let .configure(code): String(cString: strerror(code))
            }
        }
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "lilo.serial")
    /// Only touched on `queue` once started: the read handler and `close()` both end the connection.
    private var source: DispatchSourceRead?
    /// Only touched on `queue`: once the cancel handler closes `fd` there, the number may name another file.
    private var isClosed = false
    private static let readChunk = 16 * 1024
    /// Only touched on `queue`, reused by every read.
    private var readBuffer = [UInt8](repeating: 0, count: SerialConnection.readChunk)
    /// Main-actor callbacks: bytes read, and the end of the connection (unplugged or closed).
    @MainActor var onData: ((Data) -> Void)?
    @MainActor var onEnd: (() -> Void)?

    init(path: String, options: [String: Any]) throws {
        // Non-blocking open: a port without carrier would otherwise hang here.
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.open(errno) }
        do { try configure(options) } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func configure(_ options: [String: Any]) throws {
        _ = fcntl(fd, F_SETFL, 0)
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { throw Failure.configure(errno) }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CREAD | CLOCAL)
        settings.c_cflag &= ~tcflag_t(CSIZE)
        settings.c_cflag |= tcflag_t((options["dataBits"] as? Int) == 7 ? CS7 : CS8)
        if (options["stopBits"] as? Int) == 2 { settings.c_cflag |= tcflag_t(CSTOPB) } else { settings.c_cflag &= ~tcflag_t(CSTOPB) }
        switch options["parity"] as? String {
        case "even": settings.c_cflag |= tcflag_t(PARENB); settings.c_cflag &= ~tcflag_t(PARODD)
        case "odd": settings.c_cflag |= tcflag_t(PARENB | PARODD)
        default: settings.c_cflag &= ~tcflag_t(PARENB | PARODD)
        }
        if (options["flowControl"] as? String) == "hardware" {
            settings.c_cflag |= tcflag_t(CRTSCTS)
        } else {
            settings.c_cflag &= ~tcflag_t(CRTSCTS)
        }
        let baudRate = speed_t(options["baudRate"] as? Int ?? 9600)
        cfsetspeed(&settings, baudRate)
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            // Drivers that refuse a non-standard rate in termios take it through IOSSIOSPEED.
            cfsetspeed(&settings, speed_t(B9600))
            guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw Failure.configure(errno) }
            var speed = baudRate
            // IOSSIOSPEED from IOKit/serial/ioss.h, a macro Swift does not import.
            let ioSSIOSpeed: UInt = 0x8008_5402
            guard withUnsafeMutablePointer(to: &speed, { ioctl(fd, ioSSIOSpeed, $0) }) == 0 else { throw Failure.configure(errno) }
            return
        }
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let count = read(fd, &readBuffer, Self.readChunk)
            guard count > 0 else {
                // EOF or an error such as ENXIO: the device went away.
                self.close()
                return
            }
            let data = Data(readBuffer[0..<count])
            Task { @MainActor in self.onData?(data) }
        }
        source.setCancelHandler { [fd, weak self] in
            self?.isClosed = true
            Darwin.close(fd)
            Task { @MainActor in self?.onEnd?() }
        }
        self.source = source
        source.resume()
    }

    func close() {
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    func write(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed else { return continuation.resume(returning: false) }
                let written = data.withUnsafeBytes { bytes -> Bool in
                    var offset = 0
                    while offset < bytes.count {
                        let result = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                        if result < 0 { if errno == EINTR || errno == EAGAIN { continue } else { return false } }
                        offset += result
                    }
                    return true
                }
                continuation.resume(returning: written)
            }
        }
    }

    /// A nil signal is left as it is.
    func setSignals(dataTerminalReady: Bool?, requestToSend: Bool?, breakOn: Bool?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed else { return continuation.resume(returning: false) }
                func apply(_ on: Bool?, _ bit: Int32) -> Bool {
                    guard let on else { return true }
                    var bits = bit
                    return withUnsafeMutablePointer(to: &bits) { ioctl(fd, on ? TIOCMBIS : TIOCMBIC, $0) } == 0
                }
                var ok = apply(dataTerminalReady, TIOCM_DTR) && apply(requestToSend, TIOCM_RTS)
                if let breakOn { ok = ok && ioctl(fd, breakOn ? TIOCSBRK : TIOCCBRK) == 0 }
                continuation.resume(returning: ok)
            }
        }
    }

    func signals() async -> [String: Bool]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var bits: Int32 = 0
                guard !isClosed, withUnsafeMutablePointer(to: &bits, { ioctl(fd, TIOCMGET, $0) }) == 0 else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: [
                    "dataCarrierDetect": bits & TIOCM_CAR != 0,
                    "clearToSend": bits & TIOCM_CTS != 0,
                    "ringIndicator": bits & TIOCM_RNG != 0,
                    "dataSetReady": bits & TIOCM_DSR != 0
                ])
            }
        }
    }
}

// MARK: - Polyfill source

extension SerialBridge {
    /// `navigator.serial` for secure top-level documents. Bytes cross the bridge as base64.
    static let polyfillSource = """
(function(){
'use strict';
var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.liloSerial;
if(!handler||!window.isSecureContext||window.top!==window||'serial' in navigator)return;
var documentToken=Math.random().toString(36).slice(2)+Date.now().toString(36);
function toError(e){
var text=String(e&&e.message||e),m=/^(\\w+): (.*)$/.exec(text);
if(m&&m[1]==='TypeError')return new TypeError(m[2]);
return new DOMException(m?m[2]:text,m?m[1]:'NetworkError');
}
function call(action,args){
var message=Object.assign({action:action,document:documentToken},args||{});
return handler.postMessage(message).catch(function(e){throw toError(e);});
}
function toBase64(bytes){
var s='';for(var i=0;i<bytes.length;i+=32768)s+=String.fromCharCode.apply(null,bytes.subarray(i,i+32768));
return btoa(s);
}
function fromBase64(text){
var s=atob(text),bytes=new Uint8Array(s.length);for(var i=0;i<s.length;i++)bytes[i]=s.charCodeAt(i);return bytes;
}
function withHandlers(target,types){
types.forEach(function(type){target['on'+type]=null;target.addEventListener(type,function(e){var h=target['on'+type];if(typeof h==='function')h.call(target,e);});});
}
var ports={};
class SerialPort extends EventTarget{
constructor(info){super();this._info=info;this.readable=null;this.writable=null;this._controller=null;this._closing=false;withHandlers(this,['connect','disconnect']);}
get connected(){return true;}
getInfo(){var info={};if(this._info.usbVendorId!=null)info.usbVendorId=this._info.usbVendorId;if(this._info.usbProductId!=null)info.usbProductId=this._info.usbProductId;return info;}
async open(options){
if(this.readable)throw new DOMException('The port is already open.','InvalidStateError');
if(!options||!options.baudRate)throw new TypeError('A baudRate is required.');
await call('open',{id:this._info.id,baudRate:options.baudRate,dataBits:options.dataBits||8,stopBits:options.stopBits||1,parity:options.parity||'none',flowControl:options.flowControl||'none'});
var port=this;this._closing=false;
this.readable=new ReadableStream({start:function(c){port._controller=c;},cancel:function(){port._controller=null;}});
this.writable=new WritableStream({write:function(chunk){
var bytes=chunk instanceof Uint8Array?chunk:ArrayBuffer.isView(chunk)?new Uint8Array(chunk.buffer,chunk.byteOffset,chunk.byteLength):new Uint8Array(chunk);
return call('write',{id:port._info.id,data:toBase64(bytes)});
}});
}
async close(){
if(!this.readable)throw new DOMException('The port is already closed.','InvalidStateError');
this._closing=true;
var readable=this.readable,writable=this.writable,controller=this._controller;
this.readable=null;this.writable=null;this._controller=null;
if(controller){try{controller.close();}catch(e){}}
if(!readable.locked){try{await readable.cancel();}catch(e){}}
if(!writable.locked){try{await writable.close();}catch(e){}}
await call('close',{id:this._info.id});
}
setSignals(signals){return call('setSignals',Object.assign({id:this._info.id},signals||{}));}
getSignals(){return call('getSignals',{id:this._info.id});}
async forget(){await call('forget',{id:this._info.id});delete ports[this._info.id];}
}
function portFor(info){return ports[info.id]||(ports[info.id]=new SerialPort(info));}
class Serial extends EventTarget{
constructor(){super();withHandlers(this,['connect','disconnect']);}
async requestPort(options){return portFor(await call('requestPort',{filters:(options&&options.filters)||[]}));}
async getPorts(){return (await call('getPorts')).map(portFor);}
}
var serial=new Serial();
window.__liloSerialData=function(id,data){
var port=ports[id];if(port&&port._controller){try{port._controller.enqueue(fromBase64(data));}catch(e){}}
};
window.__liloSerialEnd=function(id){
var port=ports[id];if(!port||port._closing)return;
if(port._controller){try{port._controller.error(new DOMException('The device has been lost.','NetworkError'));}catch(e){}}
port.readable=null;port.writable=null;port._controller=null;
port.dispatchEvent(new Event('disconnect'));serial.dispatchEvent(new Event('disconnect'));
};
window.SerialPort=SerialPort;window.Serial=Serial;
Object.defineProperty(Navigator.prototype,'serial',{get:function(){return serial;},configurable:true,enumerable:true});
})();
"""
}
