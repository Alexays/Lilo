import CoreLocation
import OSLog
import WebKit

// MARK: - GeolocationBridge

/// Bridges `navigator.geolocation` to CoreLocation through a polyfill: macOS WebKit gives WKWebView no position provider.
@MainActor
final class GeolocationBridge: NSObject, WKScriptMessageHandler {
    private static let logger = Logger(liloCategory: "geolocation")
    static let messageHandlerName = "liloGeolocation"
    typealias PermissionDecisionHandler = (WKWebView?, String, String, @escaping (Bool) -> Void) -> Void

    /// The polyfill and its callback table are per frame, so replies target the requesting frame.
    private struct PendingRequest {
        let id: Int
        let frame: WKFrameInfo
        let isWatch: Bool
        let highAccuracy: Bool
        @MainActor var webView: WKWebView? { frame.webView }
    }

    private var locationManager: CLLocationManager?
    private var pendingRequests: [PendingRequest] = []
    private var authorizationPending: Bool = false
    var permissionDecisionHandler: PermissionDecisionHandler?

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        pruneStaleRequests()

        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let id = body["id"] as? Int else { return }

        let highAccuracy = body["highAccuracy"] as? Bool ?? false

        switch type {
        case "get", "watch":
            let request = PendingRequest(id: id, frame: message.frameInfo, isWatch: type == "watch", highAccuracy: highAccuracy)
            guard message.frameInfo.securityOrigin.isPotentiallyTrustworthy else {
                deliver(error: .permissionDenied, to: [request])
                return
            }
            requestSitePermission(forOrigin: message.frameInfo.securityOrigin.permissionOriginKey, webView: message.webView) { [weak self] granted in
                guard let self else { return }
                if granted {
                    enqueue(request)
                } else {
                    deliver(error: .permissionDenied, to: [request])
                }
            }
        case "clear":
            pendingRequests.removeAll { $0.id == id && $0.webView === message.webView }
            updateDesiredAccuracy()
            stopLocationUpdatesIfIdle()
        default:
            break
        }
    }

    func requestSitePermission(forOrigin origin: String, webView: WKWebView?, completion: @escaping (Bool) -> Void) {
        guard let permissionDecisionHandler else {
            completion(true)
            return
        }
        permissionDecisionHandler(webView, "location", origin, completion)
    }

    // MARK: Private

    private func enqueue(_ request: PendingRequest) {
        pruneStaleRequests()
        pendingRequests.append(request)

        let mgr = locationManager ?? {
            let m = CLLocationManager()
            m.delegate = self.locationManagerDelegate
            // A stationary watch then gets no fix every second, so pages and the radio can idle.
            m.distanceFilter = 10
            locationManager = m
            return m
        }()
        updateDesiredAccuracy()

        switch mgr.authorizationStatus {
        case .notDetermined:
            if !authorizationPending { authorizationPending = true; mgr.requestWhenInUseAuthorization() }
        case .denied, .restricted:
            deliver(error: .permissionDenied, to: [request])
            pendingRequests.removeLast()
            stopLocationUpdatesIfIdle()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates(on: mgr)
        @unknown default:
            break
        }
    }

    private func updateDesiredAccuracy() {
        guard let mgr = locationManager else { return }
        let accuracy = pendingRequests.contains(where: \.highAccuracy) ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        if mgr.desiredAccuracy != accuracy { mgr.desiredAccuracy = accuracy }
    }

    private func startUpdates(on mgr: CLLocationManager) {
        pruneStaleRequests()
        if hasVisibleWatchRequest {
            PerfSignposts.energy.emitEvent("locationStart")
            mgr.startUpdatingLocation()
        } else if pendingRequests.contains(where: { !$0.isWatch }) {
            mgr.requestLocation()
        } else {
            PerfSignposts.energy.emitEvent("locationStop")
            mgr.stopUpdatingLocation()
        }
    }

    /// Continuous GPS runs only for `watchPosition()` callers whose web view is in the hierarchy, so hidden tabs stop holding the
    /// radio; `reevaluateWatchers()` resumes them when shown.
    private var hasVisibleWatchRequest: Bool {
        pendingRequests.contains { $0.isWatch && $0.webView.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } == true }
    }

    /// Re-arms or pauses continuous updates after tab visibility changed. The hide side is also
    /// covered lazily (every delivery re-checks visibility), so a missed call costs one GPS tick.
    func reevaluateWatchers() {
        guard let mgr = locationManager else { return }
        pruneStaleRequests()
        if hasVisibleWatchRequest {
            PerfSignposts.energy.emitEvent("locationStart")
            mgr.startUpdatingLocation()
        } else {
            PerfSignposts.energy.emitEvent("locationStop")
            mgr.stopUpdatingLocation()
        }
    }

    fileprivate func didChangeAuthorization(status: CLAuthorizationStatus) {
        authorizationPending = false
        guard let mgr = locationManager else { return }

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates(on: mgr)
        case .denied, .restricted:
            let failed = pendingRequests; pendingRequests = []
            deliver(error: .permissionDenied, to: failed)
        default:
            break
        }
    }

    fileprivate func didUpdateLocations(_ locations: [CLLocation]) {
        pruneStaleRequests()
        guard let location = locations.last else { return }
        let oneShots = pendingRequests.filter { !$0.isWatch }
        pendingRequests = pendingRequests.filter(\.isWatch)
        deliver(location: location, to: oneShots + pendingRequests)
        if !oneShots.isEmpty { updateDesiredAccuracy() }
        stopLocationUpdatesIfIdle()
    }

    fileprivate func didFail(error: Error) {
        pruneStaleRequests()
        let failed = pendingRequests; pendingRequests = []
        deliver(error: .positionUnavailable(error.localizedDescription), to: failed)
        stopLocationUpdatesIfIdle()
    }

    private func pruneStaleRequests() {
        pendingRequests.removeAll { $0.webView == nil }
    }

    private func stopLocationUpdatesIfIdle() {
        guard !hasVisibleWatchRequest, let locationManager else { return }
        PerfSignposts.energy.emitEvent("locationStop")
        locationManager.stopUpdatingLocation()
    }

    // MARK: JS delivery

    private enum GeoError {
        case permissionDenied
        case positionUnavailable(String)

        var code: Int {
            switch self {
            case .permissionDenied: return 1
            case .positionUnavailable: return 2
            }
        }
        var message: String {
            switch self {
            case .permissionDenied: return "User denied geolocation"
            case .positionUnavailable(let m): return m
            }
        }
    }

    private func deliver(location: CLLocation, to requests: [PendingRequest]) {
        guard let payload = jsonString([
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.verticalAccuracy >= 0 ? location.altitude : NSNull(),
            "altitudeAccuracy": location.verticalAccuracy >= 0 ? location.verticalAccuracy : NSNull(),
            "heading": location.course >= 0 ? location.course : NSNull(),
            "speed": location.speed >= 0 ? location.speed : NSNull(),
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]) else { return }
        for req in requests {
            // A frozen page misses the fix; a watch gets the next one once the tab is live again.
            guard let webView = req.webView, !CompositeFreezer.suspendedWebViews.contains(webView) else { continue }
            let js = "window.__liloGeoCallback(\(req.id),'position',\(payload));"
            WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(js, in: req.frame)
            Self.logger.info("Delivered position to request \(req.id)")
        }
    }

    private func deliver(error: GeoError, to requests: [PendingRequest]) {
        guard let payload = jsonString(["code": error.code, "message": error.message]) else { return }
        for req in requests {
            guard let webView = req.webView, !CompositeFreezer.suspendedWebViews.contains(webView) else { continue }
            let js = "window.__liloGeoCallback(\(req.id),'error',\(payload));"
            WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(js, in: req.frame)
            Self.logger.info("Delivered error (code \(error.code)) to request \(req.id)")
        }
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Delegate adapter

    /// The ObjC delegate must be nonisolated, so a helper object bridges to @MainActor.
    private lazy var locationManagerDelegate: LocationManagerDelegateAdapter = .init(bridge: self)
}

// MARK: - LocationManagerDelegateAdapter

private final class LocationManagerDelegateAdapter: NSObject, CLLocationManagerDelegate {
    weak var bridge: GeolocationBridge?

    init(bridge: GeolocationBridge) { self.bridge = bridge }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak bridge, status = manager.authorizationStatus] in bridge?.didChangeAuthorization(status: status) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak bridge] in bridge?.didUpdateLocations(locations) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak bridge] in bridge?.didFail(error: error) }
    }
}

// MARK: - Polyfill source

extension GeolocationBridge {
    /// JavaScript polyfill injected at document start to override `navigator.geolocation`.
    static let polyfillSource: String = """
(function(){
'use strict';
var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.liloGeolocation;
if(!handler)return;
var nextId=Math.floor(Math.random()*0x7fffffff)*0x10000+1,callbacks={};
window.__liloGeoCallback=function(id,type,data){
var cb=callbacks[id];if(!cb)return;
if(type==='position'){
var pos={coords:{latitude:data.latitude,longitude:data.longitude,accuracy:data.accuracy,altitude:data.altitude,altitudeAccuracy:data.altitudeAccuracy,heading:data.heading,speed:data.speed},timestamp:data.timestamp};
cb.success(pos);if(!cb.watch)delete callbacks[id];
}else if(type==='error'){
var err={code:data.code,message:data.message,PERMISSION_DENIED:1,POSITION_UNAVAILABLE:2,TIMEOUT:3};
cb.error(err);if(!cb.watch)delete callbacks[id];
}};
function geo_get(success,error,options){
var id=nextId++;callbacks[id]={success:success,error:error||function(){},watch:false};
handler.postMessage({type:'get',id:id,highAccuracy:!!(options&&options.enableHighAccuracy)});
}
function geo_watch(success,error,options){
var id=nextId++,high=!!(options&&options.enableHighAccuracy);callbacks[id]={success:success,error:error||function(){},watch:true,high:high};
handler.postMessage({type:'watch',id:id,highAccuracy:high});
return id;
}
window.addEventListener('pagehide',function(){for(var id in callbacks){if(callbacks[id].watch)handler.postMessage({type:'clear',id:+id});}});
window.addEventListener('pageshow',function(e){if(!e.persisted)return;for(var id in callbacks){var cb=callbacks[id];if(cb.watch)handler.postMessage({type:'watch',id:+id,highAccuracy:cb.high});}});
function geo_clear(id){
delete callbacks[id];
handler.postMessage({type:'clear',id:id});
}
var geo={getCurrentPosition:geo_get,watchPosition:geo_watch,clearWatch:geo_clear};
try{Object.defineProperty(navigator,'geolocation',{get:function(){return geo;},configurable:false,enumerable:true});}catch(e){}
})();
"""
}
