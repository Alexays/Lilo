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
        /// The origin the permission was granted to.
        let origin: String
        let isWatch: Bool
        let highAccuracy: Bool
        /// Milliseconds a cached fix may be old to answer at once.
        let maximumAge: Double
        /// The page arms its timeout once updates start, so a permission prompt does not count against it.
        var timesOut: Bool
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

        switch type {
        case "get", "watch":
            let request = PendingRequest(id: id, frame: message.frameInfo, origin: message.frameInfo.permissionOriginKey,
                                         isWatch: type == "watch", highAccuracy: body["highAccuracy"] as? Bool ?? false,
                                         maximumAge: body["maximumAge"] as? Double ?? 0, timesOut: body["timesOut"] as? Bool ?? false)
            guard message.frameInfo.securityOrigin.isPotentiallyTrustworthy else {
                deliver(error: .permissionDenied, to: [request])
                return
            }
            requestSitePermission(forOrigin: request.origin, webView: message.webView) { [weak self] granted in
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

    /// Fails the requests `origin` runs in pages of `dataStore` once its permission is revoked, watches included, as Chrome does.
    func revoke(origin: String, in dataStore: WKWebsiteDataStore) {
        var revoked: [PendingRequest] = []
        pendingRequests.removeAll { request in
            guard request.origin == origin, request.webView?.configuration.websiteDataStore === dataStore else { return false }
            revoked.append(request)
            return true
        }
        guard !revoked.isEmpty else { return }
        deliver(error: .permissionDenied, to: revoked)
        updateDesiredAccuracy()
        stopLocationUpdatesIfIdle()
    }

    // MARK: Private

    private func enqueue(_ request: PendingRequest) {
        pruneStaleRequests()
        let mgr = locationManager ?? {
            let m = CLLocationManager()
            m.delegate = self.locationManagerDelegate
            // A stationary watch then gets no fix every second, so pages and the radio can idle.
            m.distanceFilter = 10
            locationManager = m
            return m
        }()
        let status = mgr.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways, let cached = mgr.location,
           -cached.timestamp.timeIntervalSinceNow * 1000 < request.maximumAge {
            deliver(location: cached, to: [request])
            if !request.isWatch { return }
        }
        pendingRequests.append(request)
        updateDesiredAccuracy()

        switch status {
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
        for index in pendingRequests.indices where pendingRequests[index].timesOut {
            pendingRequests[index].timesOut = false
            push(pendingRequests[index], "start")
        }
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
        pendingRequests.contains { $0.isWatch && $0.webView.map { unsafe $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } == true }
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
        let code = (error as? CLError)?.code
        // CoreLocation keeps trying after this one.
        if code == .locationUnknown { return }
        pruneStaleRequests()
        if code == .denied {
            let failed = pendingRequests; pendingRequests = []
            deliver(error: .permissionDenied, to: failed)
        } else {
            // A watch outlives the error, as in WebKit: the next fix still reaches it.
            let oneShots = pendingRequests.filter { !$0.isWatch }
            pendingRequests = pendingRequests.filter(\.isWatch)
            deliver(error: .positionUnavailable(error.localizedDescription), to: oneShots + pendingRequests)
            if !oneShots.isEmpty { updateDesiredAccuracy() }
        }
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
        let payload: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.verticalAccuracy >= 0 ? location.altitude : NSNull(),
            "altitudeAccuracy": location.verticalAccuracy >= 0 ? location.verticalAccuracy : NSNull(),
            "heading": location.course >= 0 ? location.course : NSNull(),
            "speed": location.speed >= 0 ? location.speed : NSNull(),
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { return }
        for req in requests { push(req, "position", payload) }
    }

    private func deliver(error: GeoError, to requests: [PendingRequest]) {
        let payload: [String: Any] = ["code": error.code, "message": error.message]
        for req in requests { push(req, "error", payload) }
    }

    private func push(_ request: PendingRequest, _ type: String, _ payload: Any = NSNull()) {
        // A frozen page misses the fix; a watch gets the next one once the tab is live again.
        guard let webView = request.webView, !CompositeFreezer.suspendedWebViews.contains(webView) else { return }
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("geolocation", [request.id, type, payload]),
                                                                    in: request.frame, in: PageWorld.bridgeWorld)
        Self.logger.info("Sent \(type, privacy: .public) to request \(request.id)")
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

// MARK: - Page module

extension GeolocationBridge {
    /// `navigator.geolocation`'s methods for `PageWorld`, swapped on WebKit's own `Geolocation` prototype.
    static let pageModule = #"""
    function () {
      if (typeof Geolocation !== 'function') return;
      let nextId = Math.floor(Math.random() * 0x7fffffff) * 0x10000 + 1;
      const callbacks = create(null), secure = window.isSecureContext, later = setTimeout, cancel = clearTimeout;
      const nativeGet = Geolocation.prototype.getCurrentPosition;
      const codeOf = getOwnPropertyDescriptor(GeolocationPositionError.prototype, 'code').get;
      // PositionOptions' [Clamp] unsigned long.
      const clamp = value => { const n = +value; return n > 0 ? (n < 0xffffffff ? n : 0xffffffff) : 0; };
      const receive = (id, type, data) => {
        const callback = callbacks[id];
        if (!callback) return;
        if (type === 'start') {
          if (callback.timeout !== undefined) callback.timer = apply(later, window, [timedOut, callback.timeout, id, callback]);
          callback.timeout = undefined;
          return;
        }
        apply(cancel, window, [callback.timer]);
        callback.timeout = undefined;
        if (!callback.watch) delete callbacks[id];
        if (type === 'position') {
          const { latitude, longitude, accuracy, altitude, altitudeAccuracy, heading, speed } = data;
          callback.success({ coords: { latitude, longitude, accuracy, altitude, altitudeAccuracy, heading, speed }, timestamp: data.timestamp });
        } else {
          callback.error({ code: data.code, message: data.message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
        }
      };
      const timedOut = (id, callback) => {
        if (callbacks[id] !== callback) return;
        if (!callback.watch) lilo.send('liloGeolocation', { type: 'clear', id });
        receive(id, 'error', { code: 3, message: 'Timeout expired' });
      };
      lilo.on('geolocation', receive);
      const request = (type, geolocation, success, error, options) => {
        const id = nextId++, highAccuracy = !!(options && options.enableHighAccuracy);
        const maximumAge = options ? clamp(options.maximumAge) : 0, given = options ? options.timeout : undefined;
        const timeout = given === undefined ? 0xffffffff : clamp(given), timesOut = timeout < 0xffffffff;
        // WebKit's own call applies Permissions-Policy, which refuses a cross-origin frame without allow="geolocation", and
        // the ancestors' secure context; with no timeout it asks no one. Its error is read through natives the page cannot wrap.
        const decide = code => {
          if (!callbacks[id]) return;
          if (secure && code !== 1) lilo.send('liloGeolocation', { type, id, highAccuracy, maximumAge, timesOut });
          else receive(id, 'error', { code: 1, message: 'User denied Geolocation' });
        };
        apply(nativeGet, geolocation, [() => decide(0), positionError => decide(apply(codeOf, positionError, [])), { __proto__: null, timeout: 0 }]);
        callbacks[id] = { success, error: error || (() => {}), watch: type === 'watch', highAccuracy,
                          timeout: timesOut ? timeout : undefined };
        return id;
      };
      lilo.methods(Geolocation.prototype, {
        getCurrentPosition(success, error, options) { request('get', this, success, error, options); },
        watchPosition(success, error, options) { return request('watch', this, success, error, options); },
        clearWatch(id) {
          if (callbacks[id]) apply(cancel, window, [callbacks[id].timer]);
          delete callbacks[id];
          lilo.send('liloGeolocation', { type: 'clear', id });
        },
      });
      apply(listen, window, ['pagehide', () => {
        for (const id in callbacks) if (callbacks[id].watch) lilo.send('liloGeolocation', { type: 'clear', id: +id });
      }]);
      apply(listen, window, ['pageshow', event => {
        if (!event.persisted) return;
        for (const id in callbacks) {
          if (callbacks[id].watch) lilo.send('liloGeolocation', { type: 'watch', id: +id, highAccuracy: callbacks[id].highAccuracy });
        }
      }]);
    }
    """#
}
