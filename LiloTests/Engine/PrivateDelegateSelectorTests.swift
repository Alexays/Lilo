import ObjectiveC.runtime
import WebKit
import XCTest
@testable import Lilo

/// A mismatched private delegate hook is silently never called, so each selector must match WebKit's spelling and still
/// be declared by WebKit.
@MainActor
final class PrivateDelegateSelectorTests: XCTestCase {
    private static let uiDelegateSelectors = [
        "_focusWebView:",
        "_focusWebViewFromServiceWorker:",
        "_webView:drawFooterInRect:forPageWithTitle:URL:",
        "_webView:drawHeaderInRect:forPageWithTitle:URL:",
        "_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:",
        "_webView:getWindowFrameWithCompletionHandler:",
        "_webView:mouseDidMoveOverElement:withFlags:userInfo:",
        "_webView:printFrame:pdfFirstPageSize:completionHandler:",
        "_webView:queryPermission:forOrigin:completionHandler:",
        "_webView:requestSpeechRecognitionPermissionForOrigin:decisionHandler:",
        "_webView:requestStorageAccessPanelForDomain:underCurrentDomain:completionHandler:",
        "_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:",
        "_webView:takeFocus:",
        "_webViewDidLosePointerLock:",
        "_webViewDidRequestPointerLock:completionHandler:",
        "_webViewFooterHeight:",
        "_webViewFullscreenMayReturnToInline:",
        "_webViewHeaderHeight:",
    ]

    private static let navigationDelegateSelectors = [
        "_webView:contentRuleListWithIdentifier:performedAction:forURL:",
        "_webView:didGeneratePageLoadTiming:",
        "_webView:navigation:didSameDocumentNavigation:",
        "_webView:webContentProcessDidTerminateWithReason:",
        "_webViewDidBeginNavigationGesture:",
        "_webViewWebProcessDidBecomeResponsive:",
        "_webViewWebProcessDidBecomeUnresponsive:",
    ]

    /// `_WKIconLoadingDelegate`, which no WebKit class adopts: its protocol is not in the runtime to check against.
    private static let iconLoadingDelegateSelectors = [
        "webView:shouldLoadIconWithParameters:completionHandler:",
    ]

    /// `_WKResourceLoadDelegate`, adopted by the agent capture of a tab's network requests. Like the
    /// icon delegate, no WebKit class adopts it, so its protocol is not in the runtime to check against.
    private static let resourceLoadDelegateSelectors = [
        "webView:resourceLoad:didSendRequest:",
        "webView:resourceLoad:didReceiveResponse:",
        "webView:resourceLoad:didCompleteWithError:response:",
    ]

    func testAgentCaptureClaimsEveryResourceLoadHook() {
        for name in Self.resourceLoadDelegateSelectors {
            XCTAssertTrue(AgentCapture.instancesRespond(to: NSSelectorFromString(name)), "AgentCapture no longer implements \(name)")
        }
    }

    func testEngineTabClaimsEveryHook() {
        for name in Self.uiDelegateSelectors + Self.navigationDelegateSelectors + Self.iconLoadingDelegateSelectors {
            XCTAssertTrue(
                WKWebViewTab.instancesRespond(to: NSSelectorFromString(name)),
                "WKWebViewTab no longer implements \(name)"
            )
        }
    }

    func testWebKitStillDeclaresEveryHook() {
        assertDeclared(Self.uiDelegateSelectors, in: "WKUIDelegatePrivate")
        assertDeclared(Self.navigationDelegateSelectors, in: "WKNavigationDelegatePrivate")
    }

    /// Private keys and setters the engine reads or writes behind a `responds(to:)` guard: a WebKit
    /// rename makes the guard skip silently, so the rename has to surface here.
    func testWebKitStillAnswersEveryGuardedPrivateKey() {
        let expectations: [(className: String, selectors: [String])] = [
            ("WKWebView", ["_displayCaptureState", "_isPlayingAudio", "_setDrawsBackground:", "_setIconLoadingDelegate:", "_setResourceLoadDelegate:", "_inspector", "_setOverrideDeviceScaleFactor:", "_overrideDeviceScaleFactor", "_webProcessIdentifier"]),
            ("_WKInspector", ["connect", "close", "isVisible", "isConnected", "inspectorWebView"]),
            ("_WKResourceLoadInfo", ["resourceLoadID"]),
            ("_WKLinkIconParameters", ["url", "size", "iconType"]),
            ("WKPreferences", ["_setDeveloperExtrasEnabled:", "_setAllowsPictureInPictureMediaPlayback:", "_setMediaDevicesEnabled:", "_setPrivateClickMeasurementEnabled:",
                              "_setHiddenPageDOMTimerThrottlingEnabled:", "_setHiddenPageDOMTimerThrottlingAutoIncreases:",
                              "_setPageVisibilityBasedProcessSuppressionEnabled:"]),
            ("_WKContextMenuElementInfo", ["hitTestResult"]),
            ("_WKHitTestResult", ["absoluteLinkURL", "absoluteImageURL", "absoluteMediaURL"]),
            ("_WKFeature", ["key", "name", "details", "isHidden", "defaultValue"]),
            ("_WKContentRuleListAction", ["blockedLoad"]),
            ("WKWindowFeatures", ["_wantsPopup"]),
            ("WKWebpagePreferences", ["_networkConnectionIntegrityPolicy", "_setNetworkConnectionIntegrityPolicy:"]),
            ("WKFrameInfo", ["_handle"]),
            ("_WKFrameHandle", ["frameID"]),
            ("_WKFrameTreeNode", ["info", "childFrames"]),
            ("WKWebsiteDataStore", ["_setResourceLoadStatisticsEnabled:", "_resourceLoadStatisticsEnabled", "_clearResourceLoadStatistics:"]),
        ]
        for (className, selectors) in expectations {
            guard let cls = NSClassFromString(className) else {
                XCTFail("WebKit no longer exposes \(className)")
                continue
            }
            for name in selectors {
                XCTAssertTrue(cls.instancesRespond(to: NSSelectorFromString(name)), "\(className) no longer answers \(name)")
            }
        }
    }

    private func assertDeclared(_ selectors: [String], in protocolName: String) {
        guard let proto = objc_getProtocol(protocolName) else {
            return XCTFail("WebKit no longer exposes \(protocolName)")
        }
        for name in selectors {
            let selector = NSSelectorFromString(name)
            let declared = protocol_getMethodDescription(proto, selector, false, true).name != nil
                || protocol_getMethodDescription(proto, selector, true, true).name != nil
            XCTAssertTrue(declared, "\(protocolName) no longer declares \(name)")
        }
    }
}
