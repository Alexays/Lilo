import WebKit
import XCTest
@testable import Lilo

final class FilterListConverterTests: XCTestCase {
    private func dict(_ line: String) -> [String: Any]? {
        let out = FilterListConverter.convert(line)
        return out.blocks.first ?? out.exceptions.first
    }
    private func trigger(_ line: String) -> [String: Any]? { dict(line)?["trigger"] as? [String: Any] }
    private func actionType(_ line: String) -> String? {
        (dict(line)?["action"] as? [String: Any])?["type"] as? String
    }
    private func isDropped(_ line: String) -> Bool {
        let out = FilterListConverter.convert(line)
        return out.blocks.isEmpty && out.exceptions.isEmpty && out.cosmetic.isEmpty && out.domainCosmetic.isEmpty
            && out.cosmeticExceptions.isEmpty && out.scriptlets.isEmpty && out.scriptletExceptions.isEmpty
            && out.procedural.isEmpty && out.proceduralExceptions.isEmpty
    }

    func testDomainAnchorBlockRule() {
        let out = FilterListConverter.convert("||ads.example.com^")
        XCTAssertEqual(out.blocks.count, 1)
        XCTAssertTrue(out.exceptions.isEmpty)
        XCTAssertEqual(actionType("||ads.example.com^"), "block")
        XCTAssertEqual(
            trigger("||ads.example.com^")?["url-filter"] as? String,
            "^https?://([^/]+\\.)?ads\\.example\\.com[^-a-zA-Z0-9._%]"
        )
    }

    /// `$to` holds only where the url-filter carries the request host: never as `if-domain`, which is the page's.
    func testRequestHostOptionIsKeptOnlyWhereTheFilterCarriesIt() throws {
        let any = FilterListConverter.convert("*$script,3p,to=com|ads.example.net").blocks.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertEqual(any, [#"^[^:]+://+([^:/]+\.)?com[:/]"#, #"^[^:]+://+([^:/]+\.)?ads\.example\.net[:/]"#])
        let regex = #"/^https:\/\/[-0-9a-z]{5,}\.(?:com|org)\/\d{1,2}\/[0-9a-f]{4}$/$script,to=com|org"#
        XCTAssertEqual(FilterListConverter.convert(regex).blocks.count, 2, "each alternative pins .com or .org")
        XCTAssertEqual(FilterListConverter.convert("||cdn.ads.example^$script,to=ads.example").blocks.count, 1)
        for line in [
            #"/^https:\/\/[a-z]+\.net\//$script,to=com"#, #"/^https:\/\/.+\.com\//$script,to=com"#, #"/\/[0-9a-f]{32}\.js/$script,to=com"#,
            "||ads.example^$to=cdn.ads.example", "||ads.example$to=example", "*$script,to=~com", "*$script,to=example.*", "/ad.js$to=com"
        ] {
            XCTAssertTrue(isDropped(line), "cannot carry the host: \(line)")
        }
        // WebKit takes the filters.
        let rules = FilterListConverter.convert("*$script,to=com\n" + regex).blocks
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: rules), encoding: .utf8))
        let compiled = expectation(description: "compiled")
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "lilo-tests-to", encodedContentRuleList: json) { list, error in
            XCTAssertNotNil(list, "\(String(describing: error))")
            compiled.fulfill()
        }
        wait(for: [compiled], timeout: 10)
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "lilo-tests-to") { _ in }
    }

    func testExceptionBecomesIgnorePreviousRules() {
        let out = FilterListConverter.convert("@@||good.example^")
        XCTAssertEqual(out.exceptions.count, 1)
        XCTAssertTrue(out.blocks.isEmpty)
        XCTAssertEqual(actionType("@@||good.example^"), "ignore-previous-rules")
    }

    func testThirdPartyAndResourceTypeOptions() {
        let t = trigger("||x.example^$third-party,script,image")
        XCTAssertEqual(t?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual((t?["resource-type"] as? [String])?.sorted(), ["image", "script"])
    }

    func testFirstPartyAndNegatedThirdParty() {
        XCTAssertEqual(trigger("||x.example^$~third-party")?["load-type"] as? [String], ["first-party"])
    }

    func testMixedDomainOptionSkipsBlocksAndWidensExceptions() {
        XCTAssertTrue(isDropped("||x.example^$domain=a.example|~sub.a.example"), "The block would run on sub.a.example")
        XCTAssertEqual(trigger("@@||x.example^$domain=a.example|~sub.a.example")?["if-domain"] as? [String], ["*a.example"])
        XCTAssertNil(trigger("@@||x.example^$domain=a.example|~sub.a.example")?["unless-domain"])
        XCTAssertEqual(trigger("||x.example^$domain=~only.example")?["unless-domain"] as? [String], ["*only.example"])
    }

    func testUnknownOrUnexpressibleOptionsSkipTheRule() {
        for line in [
            "||x.example^$uritransform=/a/b/", "||x.example^$urltransform=/a/b/", "||x.example^$urlskip=?url",
            "@@||x.example^$ghide", "@@||x.example^$ehide", "@@||x.example^$shide", "||x.example^$denyallow=a.example",
            "*$script,3p,denyallow=cdn.example|x.example,domain=site.example",
            "||x.example/caf\u{E9}^", "||x.example^$domain=caf\u{E9}.example",
            "||x.example^$strict1p", "||x.example^$ipaddress=1.2.3.4", "||x.example^$popunder", "||x.example^$someday",
            "||x.example^$~script,~image,~stylesheet,~font,~media,~xhr,~ping,~document"
        ] {
            XCTAssertTrue(isDropped(line), "should skip: \(line)")
        }
    }

    func testOptionAliases() {
        XCTAssertEqual(trigger("||x.example^$from=a.example")?["if-domain"] as? [String], ["*a.example"])
        XCTAssertEqual(trigger("||x.example^$3p")?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(trigger("||x.example^$1p")?["load-type"] as? [String], ["first-party"])
        XCTAssertEqual(trigger("||x.example^$strict3p")?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(trigger("||x.example^$xhr,frame,doc,css")?["resource-type"] as? [String], ["document", "raw", "style-sheet"])
    }

    func testNegatedTypeKeepsTheOtherTypes() {
        XCTAssertEqual(trigger("||x.example^$~script,~image")?["resource-type"] as? [String],
                       ["document", "font", "media", "ping", "raw", "style-sheet"])
        XCTAssertEqual(trigger("||x.example^$script,~image")?["resource-type"] as? [String], ["script"])
    }

    func testBadfilterDisablesTheRuleItRepeats() {
        let out = FilterListConverter.convert(
            """
            ||ads.example^$script,3p
            ||keep.example^$script
            @@||ok.example^
            ||ads.example^$script,3p,badfilter
            @@||ok.example^$badfilter
            """
        )
        XCTAssertEqual(out.blocks.map { ($0["trigger"] as? [String: Any])?["url-filter"] as? String },
                       ["^https?://([^/]+\\.)?keep\\.example[^-a-zA-Z0-9._%]"])
        XCTAssertTrue(out.exceptions.isEmpty)
    }

    func testImportantBlocksAreSeparated() {
        let out = FilterListConverter.convert("||a.example^\n||b.example^$important,script")
        XCTAssertEqual(out.blocks.count, 1)
        XCTAssertEqual(out.important.count, 1)
        XCTAssertEqual((out.important.first?["trigger"] as? [String: Any])?["resource-type"] as? [String], ["script"])
    }

    func testEntityDomainsCannotWidenNetworkRules() {
        XCTAssertEqual(trigger("||x.example^$domain=example.*|a.example")?["if-domain"] as? [String], ["*a.example"])
        XCTAssertTrue(isDropped("||x.example^$domain=example.*"), "Without its only site the rule would apply everywhere")
        XCTAssertTrue(isDropped("||x.example^$domain=~example.*|~b.example"), "Without an exclusion the rule would widen")
        XCTAssertTrue(isDropped(#"||x.example^$domain=/^a\.[a-z]+\.example$/"#))
    }

    func testCosmeticDomainsKeepEntitiesAndStripFrameMarker() {
        let out = FilterListConverter.convert("example.*,x.example>>##+js(set, a, 1)")
        XCTAssertEqual(out.scriptlets.first?.domains, ["example.*", "x.example"])
    }

    func testIfDirectivesKeepOnlySafariBranches() {
        let out = FilterListConverter.convert(
            """
            !#if env_safari
            ||safari.example^
            !#else
            ||not-safari.example^
            !#endif
            !#if env_chromium
            ||chromium.example^
            !#if !env_mobile
            ||nested.example^
            !#endif
            !#else
            ||other.example^
            !#endif
            !#if !cap_html_filtering
            ||no-html.example^
            !#endif
            """
        )
        XCTAssertEqual(out.blocks.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String },
                       ["safari", "other", "no-html"].map { "^https?://([^/]+\\.)?\($0)\\.example[^-a-zA-Z0-9._%]" })
    }

    func testPathRuleKeptNotTreatedAsRegexLiteral() {
        // Starts with "/" but is a path substring rule, not a /regex/ literal.
        XCTAssertEqual(trigger("/ads/banner.gif")?["url-filter"] as? String, "/ads/banner\\.gif")
    }

    func testRegexRuleExpandsIntoTheWebKitSubset() {
        let out = FilterListConverter.convert(#"/^https?:\/\/[a-z\d]{3}\.(?:com|net)\/ad\d+\.js/$script,3p"#)
        let filters = out.blocks.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertEqual(filters, [
            #"^https?:\/\/[a-z0-9][a-z0-9][a-z0-9]\.(com)\/ad[0-9][0-9]*\.js"#,
            #"^https?:\/\/[a-z0-9][a-z0-9][a-z0-9]\.(net)\/ad[0-9][0-9]*\.js"#
        ])
        XCTAssertEqual((out.blocks.first?["trigger"] as? [String: Any])?["resource-type"] as? [String], ["script"])
        XCTAssertEqual(trigger("/ad[0-9]{1,2}x$/")?["url-filter"] as? String, "ad[0-9][0-9]?x$")
        XCTAssertEqual(trigger(#"/\/x(\/y)?\.js$/$domain=a.example"#)?["url-filter"] as? String, #"\/x(\/y)?\.js$"#)
    }

    func testMatchAllRulesNeedASite() {
        XCTAssertEqual(trigger("*$script,domain=site.example")?["url-filter"] as? String, ".*")
        XCTAssertEqual(trigger("$image,domain=site.example")?["if-domain"] as? [String], ["*site.example"])
        XCTAssertEqual(trigger("*/ads/")?["url-filter"] as? String, "/ads/")
    }

    func testRedirectAndRemoveparamBecomeExtensionRules() {
        let out = FilterListConverter.convert("""
        ||imasdk.googleapis.com/js/sdkloader/ima3.js$script,redirect=google-ima.js,domain=player.example|~safe.example
        ||ads.example^$xhr,redirect-rule=nooptext:5,important
        ||tracker.example^$removeparam=utm_source
        @@||imasdk.googleapis.com^$domain=safe.example
        ||x.example^$redirect=unknown-resource
        ||x.example^$removeparam=/^utm_/
        """)
        XCTAssertEqual(out.extensionRules.count, 4)
        let ima = out.extensionRules[0]
        XCTAssertEqual((ima["action"] as? [String: Any])?["redirect"] as? [String: String], ["extensionPath": "/resources/google-ima.js"])
        let condition = ima["condition"] as? [String: Any]
        XCTAssertEqual(condition?["urlFilter"] as? String, "||imasdk.googleapis.com/js/sdkloader/ima3.js")
        XCTAssertEqual(condition?["initiatorDomains"] as? [String], ["player.example"])
        XCTAssertEqual(condition?["excludedInitiatorDomains"] as? [String], ["safe.example"])
        XCTAssertEqual(condition?["resourceTypes"] as? [String], ["script"])
        XCTAssertEqual(out.extensionRules[1]["priority"] as? Int, 3, "important outranks exceptions")
        let removeparam = out.extensionRules[2]
        XCTAssertEqual(((removeparam["action"] as? [String: Any])?["redirect"] as? [String: Any])?["transform"] as? [String: [String: [String]]],
                       ["queryTransform": ["removeParams": ["utm_source"]]])
        let removeparamCondition = removeparam["condition"] as? [String: Any]
        XCTAssertEqual(removeparamCondition?["resourceTypes"] as? [String], ["main_frame", "ping", "sub_frame", "xmlhttprequest"])
        XCTAssertEqual(removeparamCondition?["urlFilter"] as? String, "||tracker.example^*utm_source=",
                       "a host rule only matches the URLs holding the parameter, not every request to the host")
        XCTAssertEqual((out.extensionRules[3]["action"] as? [String: Any])?["type"] as? String, "allow")
        XCTAssertEqual(out.exceptions.count, 1, "an exception also holds among the content rules")
        let generic = FilterListConverter.convert("$removeparam=utm_source").extensionRules.first?["condition"] as? [String: Any]
        XCTAssertEqual(generic?["urlFilter"] as? String, "utm_source=", "a rule for any URL only matches those holding the parameter")
        XCTAssertTrue(FilterListConverter.convert("$removeparam").extensionRules.isEmpty, "emptying every query needs a pattern")
        XCTAssertTrue(out.blocks.isEmpty, "a redirect is not also a plain block")
    }

    func testEntityExclusionsCannotWidenARedirect() {
        XCTAssertNil(FilterListConverter.declarativeRule("||x.example^$redirect=noopjs,domain=~example.*"),
                     "without its exclusion the redirect would run on the excluded sites")
        XCTAssertNotNil(FilterListConverter.declarativeRule("@@||x.example^$domain=a.example|~example.*"), "an exception may drop one")
    }

    func testAbpHasAndResourceNamesAreNormalized() {
        XCTAssertEqual(FilterListConverter.convert("a.example##div:-abp-has(.ad)").domainCosmetic.first?.selector, "div:has(.ad)")
        XCTAssertEqual(FilterListConverter.convert("a.example##+js(cookie-remover.js, consent)").scriptlets.first?.name, "remove-cookie")
        XCTAssertEqual(FilterListConverter.convert("a.example##.x:remove-attr(onclick)").procedural.count, 1)
        XCTAssertTrue(FilterListConverter.convert("a.example##.x:remove-attr(onclick)").domainCosmetic.isEmpty)
    }

    func testListSelectionPicksTheLists() {
        var selection = FilterListService.ListSelection()
        selection.languages = ["fr-FR", "en-US"]
        let names = FilterListService.sources(for: selection).map(\.lastPathComponent)
        XCTAssertEqual(names.first, "quick-fixes.txt")
        XCTAssertTrue(names.contains("liste_fr.txt"))
        XCTAssertTrue(names.contains("easyprivacy.txt") && names.contains("badware.txt") && names.contains("easylist-cookies.txt"))
        XCTAssertFalse(names.contains("annoyances-others.txt"))
        selection = FilterListService.ListSelection(trackers: false, cookieNotices: false, annoyances: true, badware: false, regional: false,
                                                    languages: ["fr"])
        let others = FilterListService.sources(for: selection).map(\.lastPathComponent)
        XCTAssertFalse(others.contains("liste_fr.txt") || others.contains("easyprivacy.txt") || others.contains("badware.txt"))
        XCTAssertTrue(others.contains("annoyances-others.txt"))
    }

    func testWildcardAndAnchors() {
        XCTAssertEqual(trigger("|http://ad.*/track|")?["url-filter"] as? String, "^http://ad\\..*/track$")
    }

    func testSkippedLines() {
        for line in [
            "", "! a comment", "[Adblock Plus 2.0]",
            "||x.example^$redirect=noopjs", "||x.example^$removeparam=utm_source", "||x.example^$csp=script-src 'none'",
            "/^https?:\\/\\/(?=x)ad/", "/ad\\b/", "/a{1,200}/", "*$script", "/(a|b)+/"
        ] {
            XCTAssertTrue(isDropped(line), "should skip: \(line)")
        }
        XCTAssertNil(dict("example.com##.ad-banner"), "a cosmetic rule is not a network rule")
    }

    func testGenericCosmeticSelectors() {
        XCTAssertEqual(FilterListConverter.convert("##.ad-banner").cosmetic, [".ad-banner"])
        XCTAssertEqual(FilterListConverter.convert("###sponsored").cosmetic, ["#sponsored"])
        // Domain-scoped, exceptions, procedural, and ABP-extended selectors are NOT generic CSS.
        XCTAssertTrue(FilterListConverter.convert("example.com##.ad").cosmetic.isEmpty)
        for line in ["#@#.ad", "##.box:-abp-properties(width:1px)", "##.box:style(height:0)", "##+js(set, x, true)"] {
            XCTAssertTrue(isDropped(line), "should skip: \(line)")
        }
    }

    func testConvertCollectsCosmetic() {
        let out = FilterListConverter.convert(
            """
            ||ads.example^
            ##.generic-ad
            example.com##.domain-scoped
            ##.box:-abp-has(.x)
            ##.box:-abp-properties(width:1px)
            """
        )
        XCTAssertEqual(out.blocks.count, 1)
        XCTAssertEqual(out.cosmetic, [".generic-ad", ".box:has(.x)"])
    }

    func testDomainCosmeticRuleParsing() {
        XCTAssertEqual(
            FilterListConverter.convert("youtube.com##.ad-slot").domainCosmetic,
            [FilterListConverter.DomainCosmetic(domains: ["youtube.com"], selector: ".ad-slot")]
        )
    }

    func testDomainCosmeticMultipleAndNegatedDomains() {
        XCTAssertEqual(FilterListConverter.convert("a.example,b.example##.x").domainCosmetic.first?.domains, ["a.example", "b.example"])
    }

    /// uBO compiles an excluded host as an exception there, for site, generic, procedural and scriptlet rules alike.
    func testExcludedHostsBecomeExceptions() {
        let site = FilterListConverter.convert("a.example,~sub.a.example##.x")
        XCTAssertEqual(site.domainCosmetic, [.init(domains: ["a.example"], selector: ".x")])
        XCTAssertEqual(site.cosmeticExceptions, [.init(domains: ["sub.a.example"], selector: ".x")])
        let generic = FilterListConverter.convert("~a.example,~b.example##.x")
        XCTAssertEqual(generic.cosmetic, [".x"])
        XCTAssertEqual(generic.cosmeticExceptions, [.init(domains: ["a.example", "b.example"], selector: ".x")])
        let procedural = FilterListConverter.convert("a.example,~b.a.example##.x:has-text(ad)")
        XCTAssertEqual(procedural.procedural, [.init(domains: ["a.example"], selector: ".x:has-text(ad)")])
        XCTAssertEqual(procedural.proceduralExceptions, [.init(domains: ["b.a.example"], selector: ".x:has-text(ad)")])
        let scriptlet = FilterListConverter.convert("a.*,~a.com##+js(aopr, x)")
        XCTAssertEqual(scriptlet.scriptlets, [.init(domains: ["a.*"], name: "abort-on-property-read", args: ["x"])])
        XCTAssertEqual(scriptlet.scriptletExceptions, [.init(domains: ["a.com"], name: "abort-on-property-read", args: ["x"])])
        XCTAssertTrue(isDropped("~a.example##+js(aopr, x)"), "generic scriptlets are not supported")
        XCTAssertTrue(isDropped("~a.example##.x:has-text(ad)"), "generic procedural rules are not supported")
    }

    func testScriptletExceptionsAndTheirTable() {
        let out = FilterListConverter.convert("""
        a.example#@#+js(set, x, 1)
        b.example#@#+js()
        #@#+js(set, y, 1)
        c.example#@#+js(not-a-scriptlet)
        c.example#@#+js(trusted-set-cookie, a, b)
        """)
        XCTAssertEqual(out.scriptletExceptions, [
            .init(domains: ["a.example"], name: "set-constant", args: ["x", "1"]), .init(domains: ["b.example"], name: "", args: []),
            .init(domains: ["c.example"], name: "trusted-set-cookie", args: ["a", "b"])
        ], "an exception needs no trust and no domain-less one applies")
        XCTAssertTrue(out.scriptlets.isEmpty)
        let table = FilterListConverter.scriptletTable(
            from: [.init(domains: ["a.example"], name: "set-constant", args: ["x", "1"])],
            exceptions: [.init(domains: ["a.example"], name: "set-constant", args: ["x", "1"])], cap: 1
        )
        XCTAssertEqual(table["a.example"]?.map { $0[0] as? String }, ["@set-constant"], "exceptions come ahead of the cap")
    }

    func testProceduralSpellingOfPlainCSSIsACosmetic() {
        XCTAssertEqual(FilterListConverter.convert("a.example#?#.x:has(.y)").domainCosmetic, [.init(domains: ["a.example"], selector: ".x:has(.y)")])
        XCTAssertEqual(FilterListConverter.convert("#?#.generic").cosmetic, [".generic"])
        XCTAssertEqual(FilterListConverter.convert("a.example#@?#.x").cosmeticExceptions, [.init(domains: ["a.example"], selector: ".x")])
        XCTAssertEqual(FilterListConverter.convert("a.example#?#.x:has-text(y)").procedural.count, 1)
    }

    func testHTMLFiltersAreSkipped() {
        for line in ["a.example##^script:has-text(ad)", "a.example##^responseheader(set-cookie)", "a.example#@#^script"] {
            XCTAssertTrue(isDropped(line), "WebKit cannot filter HTML: \(line)")
        }
    }

    /// A plain `:style()` rule is site CSS, applied by the style sheet; one that could break out of its rule stays procedural.
    func testPlainStyleRulesBecomeSiteCSS() {
        XCTAssertEqual(FilterListConverter.convert("a.example##.bar:has(> p):style(height: 0 !important)").domainCosmetic,
                       [.init(domains: ["a.example"], selector: ".bar:has(> p){height: 0 !important}")])
        XCTAssertEqual(FilterListConverter.convert("a.example#@#.bar:style(height: 0)").cosmeticExceptions,
                       [.init(domains: ["a.example"], selector: ".bar{height: 0}")])
        for line in ["a.example##.x:style(background: url(https://t.example/p))", "a.example##.x:style(a: b} body {c: d)",
                     "a.example##.x:has-text(ad):style(height: 0)"] {
            let out = FilterListConverter.convert(line)
            XCTAssertTrue(out.domainCosmetic.isEmpty, line)
            XCTAssertEqual(out.procedural.count, 1, line)
        }
        XCTAssertTrue(isDropped("##.x:style(height: 0)"), "generic :style() rules are not supported")
        XCTAssertTrue(isDropped("a.example##.x {height: 0}"))
    }

    /// The scripts read site exceptions; a native rule carries them as `unless-domain`, entities aside.
    func testNativeGenericRulesHonorSiteExceptions() {
        let out = FilterListConverter.convert("""
        ##[data-ad-name]
        ##[data-ad-slot]
        a.example,b.*#@#[data-ad-name]
        ~c.example##[data-ad-slot]
        """)
        let generic = FilterListConverter.genericCosmetics(from: out.cosmetic, exceptions: out.cosmeticExceptions, cap: 10)
        XCTAssertEqual(generic.cssRules.map { ($0["trigger"] as? [String: Any])?["unless-domain"] as? [String] },
                       [["*a.example"], ["*c.example"]])
    }

    func testIgnoredAndAliasedOptions() {
        XCTAssertEqual(trigger("||x.example^$doc,reason=tracker")?["resource-type"] as? [String], ["document"])
        XCTAssertEqual(trigger(#"||x.example^$doc,reason="known scam""#)?["resource-type"] as? [String], ["document"])
        XCTAssertTrue(isDropped(#"||x.example^$doc,reason="scam, script""#), "a quoted reason with a comma cannot be split")
        let rewrite = FilterListConverter.declarativeRule("||ads.example/v.mp4$media,rewrite=abp-resource:blank-mp4,domain=a.example")
        XCTAssertEqual(((rewrite?["action"] as? [String: Any])?["redirect"] as? [String: Any])?["extensionPath"] as? String,
                       "/resources/noop-1s.mp4")
        XCTAssertNil(FilterListConverter.declarativeRule("||ads.example^$rewrite=https://elsewhere.example/"))
        XCTAssertEqual(FilterListConverter.convert("a.example##+js(prevent-window-open, ad)").scriptlets.first?.name, "no-window-open-if")
    }

    func testDomainCosmeticRejectsNonDomainScoped() {
        XCTAssertEqual(FilterListConverter.convert("##.generic").cosmetic, [".generic"])
        XCTAssertTrue(isDropped("a.example#@#"))
        XCTAssertEqual(FilterListConverter.convert("a.example##.x:has-text(y)").procedural.count, 1)
        XCTAssertEqual(FilterListConverter.convert("a.example##+js(set, x, 1)").scriptlets.count, 1)
        XCTAssertEqual(FilterListConverter.convert("||ads.example^").blocks.count, 1)
        for line in ["##.generic", "a.example##.x:has-text(y)", "a.example##+js(set, x, 1)", "||ads.example^"] {
            XCTAssertTrue(FilterListConverter.convert(line).domainCosmetic.isEmpty, "not domain cosmetic: \(line)")
        }
    }

    func testConvertPopulatesDomainCosmetic() {
        let out = FilterListConverter.convert("""
        ##.generic
        youtube.com##.ad-slot
        a.example,b.example##.promo
        """)
        XCTAssertEqual(out.cosmetic, [".generic"])
        XCTAssertEqual(out.domainCosmetic.count, 2)
        XCTAssertEqual(out.domainCosmetic.first?.domains, ["youtube.com"])
        XCTAssertEqual(out.domainCosmetic.first?.selector, ".ad-slot")
    }

    func testCosmeticExceptionsAndGenericHide() {
        let out = FilterListConverter.convert("""
        ##.generic
        ##.excepted
        #@#.excepted
        a.example,~b.example#@#.promo
        a.example#@#.x:has-text(ad)
        @@||site.example^$generichide
        @@||other.example^$ghide,elemhide
        @@||path.example/x$generichide
        @@*$ghide,domain=a.example|b.*
        @@$generichide,domain=c.example
        @@||entity.*^$ghide
        @@*$ghide,domain=d.example|~e.d.example
        @@*$ghide,xhr,domain=f.example
        """)
        XCTAssertEqual(out.cosmetic, [".generic"])
        XCTAssertEqual(out.cosmeticExceptions, [FilterListConverter.DomainCosmetic(domains: ["a.example"], selector: ".promo")])
        XCTAssertEqual(out.proceduralExceptions, [FilterListConverter.DomainCosmetic(domains: ["a.example"], selector: ".x:has-text(ad)")])
        XCTAssertEqual(out.genericHide, ["site.example", "other.example", "a.example", "b.*", "c.example", "entity.*"])
        XCTAssertTrue(out.exceptions.isEmpty, "a generichide exception is not a network exception")
    }

    func testSiteCosmeticTableKeepsExceptionsAheadOfTheCap() {
        let table = FilterListConverter.siteCosmeticTable(
            cosmetics: [.init(domains: ["a.example"], selector: ".ad"), .init(domains: ["b.example"], selector: ".ad")],
            exceptions: [.init(domains: ["a.example"], selector: ".promo")],
            genericHide: ["c.example"],
            cap: 3
        )
        XCTAssertEqual(table, ["c.example": ["@@"], "a.example": ["@.promo", ".ad"]])
    }


    func testCombinedRulesOrdersBlocksCssThenExceptions() {
        let blocks: [[String: Any]] = [["b": 1]]
        let css: [[String: Any]] = [["c": 1]]
        let exc: [[String: Any]] = [["e": 1]]
        let important: [[String: Any]] = [["i": 1]]
        let out = FilterListConverter.combinedRules(
            blocks: blocks, cssRules: css, exceptions: exc, important: important, limit: 100
        )
        XCTAssertEqual(out.count, 4)
        XCTAssertNotNil(out[0]["b"])
        XCTAssertNotNil(out[1]["c"])
        XCTAssertNotNil(out[2]["e"])
        XCTAssertNotNil(out[3]["i"], "An important block follows the exceptions so none overrides it")
    }

    func testCombinedRulesReservesExceptionsAndCssOverBlocks() {
        let blocks: [[String: Any]] = Array(repeating: ["b": 1], count: 10)
        let css: [[String: Any]] = [["c": 1]]
        let exc: [[String: Any]] = [["e": 1]]
        let out = FilterListConverter.combinedRules(blocks: blocks, cssRules: css, exceptions: exc, important: [], limit: 5)
        XCTAssertEqual(out.count, 5)          // 1 exception + 1 css reserved leaves room for 3 blocks
        XCTAssertNotNil(out.last?["e"])       // exception stays last
    }

    func testParseScriptletArgsEscapedComma() {
        XCTAssertEqual(FilterListConverter.parseScriptletArgs(#"trusted-replace-xhr-response, /"\}{2\,4}/, $1"#),
                       ["trusted-replace-xhr-response", #"/"\}{2,4}/"#, "$1"])
    }

    func testParseScriptletArgsEmptyMiddleArg() {
        XCTAssertEqual(FilterListConverter.parseScriptletArgs("json-prune-fetch-response, a b, , url:player"),
                       ["json-prune-fetch-response", "a b", "", "url:player"])
    }

    func testScriptletRuleUnquotesQuotedArgs() {
        let out = FilterListConverter.convert("!#trusted on\n" + #"www.youtube.com##+js(trusted-rpfr, '"adPlacements"', '"no_ads"', player?)"#)
        XCTAssertEqual(out.scriptlets.first?.args, [#""adPlacements""#, #""no_ads""#, "player?"])
        XCTAssertEqual(FilterListConverter.parseScriptletArgs(#"set, 'a, b' , "it\"s", 'x'y"#), ["set", "a, b", #"it"s"#, "'x'y"])
    }

    func testScriptletRuleResolvesYouTubeScriptlets() {
        let out = FilterListConverter.convert("""
        !#trusted on
        www.youtube.com##+js(nano-stb, [native code], 17000, 0.001)
        www.youtube.com##+js(rmnt, script, window\\,"fetch")
        www.youtube.com##+js(trusted-prevent-dom-bypass, Node.prototype.appendChild, fetch)
        """)
        XCTAssertEqual(out.scriptlets.map(\.name), ["adjust-setTimeout", "remove-node-text", "trusted-prevent-dom-bypass"])
        XCTAssertEqual(out.scriptlets[1].args, ["script", #"window,"fetch""#])
    }

    /// uBO's YouTube defuse rules as its quick fixes and filters carry them in October 2026: all convert, but the
    /// one its `!#if env_firefox` block keeps for Firefox.
    func testCurrentUBlockOriginYouTubeRulesAllConvert() {
        let rules = #"""
        !#if !env_mv3
        !#if !cap_html_filtering
        !#if env_firefox
        youtube.com##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots legacyImportant)
        !#endif
        !#endif
        !#endif
        www.youtube.com##+js(rpnt, script, /(\(function serverContract\(\)|^if \(window\.ytcsi)/, (()=>{if("YOUTUBE_PREMIUM_LOGO"===window.ytInitialData?.topbar?.desktopTopbarRenderer?.logo?.topbarLogoRenderer?.iconImage?.iconType||"YOUTUBE_PREMIUM_LOGO"===document.getElementById("masthead")?.attributes?.["logo-type"]?.value||location.href.startsWith("https://www.youtube.com/tv#/"))return;const e=window.ytcfg.data_.INNERTUBE_CONTEXT.client.userAgent\,t=["channel"\,"lactmilli"\,"inline"\,"yahi"];let r=!1\,o=t;const n=t=>{if(t){let r=e?.match?.(/Mozilla\/5\.0 \([^)]+/)?.[0];window.ytcfg.data_.INNERTUBE_CONTEXT.client.userAgent=r?e.replace?.(r\,r+"; "+t):e}else window.ytcfg.data_.INNERTUBE_CONTEXT.client.userAgent=e}\,a=()=>{let e=document.getElementById("movie_player");return{player:e\,response:e?.getPlayerResponse?.()\,stats:e?.getStatsForNerds?.()\,progress:e?.getProgressState?.()\,buffer:e?.getPlayerStateObject?.()?.isBuffering}}\,l=(e\,t\,r)=>e&&"0.00 s"===t?.buffer_health_seconds&&"0x0"===t?.resolution&&r.length>0\,s=()=>{let{player:e\,response:t\,stats:n\,buffer:s}=a();e&&l(s\,n\,o)&&(t?.playbackTracking?.videostatsPlaybackUrl?.baseUrl?.includes?.("reloadxhr")&&(o=o.slice(1))\,r=!0)};document.addEventListener("DOMContentLoaded"\,(function(){const e=()=>{let e\,s\,{player:i\,response:d\,stats:c\,progress:p\,buffer:y}=a();if(i&&(window.location.href.includes("/watch?")||window.location.href.includes("/embed/"))){if(p&&p.duration>0&&(p.loaded<p.duration||p.duration-p.current>1)||d?.videoDetails?.isLive){if(c&&!c?.debug_info?.startsWith?.("SSAP\, AD")){const t=new URLSearchParams(window.location.search)\,a=d.videoDetails?.videoId\,u=d.playerConfig?.playbackStartConfig?.startSeconds||parseInt(t.get("t")\,10)||0\,g=d.playabilityStatus?.errorScreen\,w=JSON.stringify(g?.playerErrorMessageRenderer?.subreason?.runs||g?.playerInterstitialRenderer?.content?.interstitialViewModel?.description?.commandRuns);return void("UNPLAYABLE"===d?.playabilityStatus?.status&&!g?.playerErrorMessageRenderer?.playerCaptchaViewModel&&w?.includes?.("WEB_PAGE_TYPE_UNKNOWN")&&w?.includes?.("https://support.google.com/youtube/answer/3037019")?(o=o.slice(1)\,o.length>0?n(o[0]):n("")\,r=!1\,i.loadVideoById(a\,u)):0===o.length?(r=!1\,n("")):l(y\,c\,o)&&r?(n(o[0])\,r=!1\,i.loadVideoById(a\,u)):!r&&p.current-u>.1&&p.current-u<5&&location.href.includes("&list=")&&null===i.getPlaylistId?.()&&(e=document.querySelector("yt-playlist-manager")\,s=e?.getPlaylistData?.()\,s&&(e.setPlaylistData?.(s)\,e.setPlayerPlaybackControlData?.({playlistPanelRenderer:s}))))}c&&p.duration>0&&i.seekTo?.(p.duration)}}else o=t};e()\,new MutationObserver((()=>{e()})).observe(document\,{childList:!0\,subtree:!0})}))\,window.Map.prototype.has=new Proxy(window.Map.prototype.has\,{apply:(e\,t\,o)=>("onSnackbarMessage"!==o?.[0]||r||s()\,Reflect.apply(e\,t\,o))})\,window.Array.prototype.push=new Proxy(window.Array.prototype.push\,{apply:(e\,t\,r)=>{let o=r?.[0];return!o||"object"!=typeof o||"Uint8Array"!==o.constructor.name||o.buffer?.byteLength!==o.length||105!==o.length&&104!==o.length||(console.log(o)\,s())\,Reflect.apply(e\,t\,r)}});const i={apply:(e\,t\,r)=>{const o=r[0];return"function"==typeof o&&o.toString().includes("onAbnormalityDetected")&&(r[0]=function(){})\,Reflect.apply(e\,t\,r)}};window.Promise.prototype.then=new Proxy(window.Promise.prototype.then\,i)})();$1, sedCount, 1, excludes, MutationObserver, condition, /serverContract|js_ld/)
        www.youtube.com##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.attestationRequest][?.context.client.userAgent*="channel"].context.client[?.clientName=="WEB"]+={"clientScreen":"CHANNEL"})
        www.youtube.com##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.attestationRequest][?.context.client.userAgent*="lactmilli"]+={"params":"8AUB"})
        www.youtube.com##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.attestationRequest][?.context.client.userAgent*="yahi"]+={"params":"YAHI"})
        www.youtube.com##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.attestationRequest][?.context.client.userAgent*="instream"].playbackContext[?.contentPlaybackContext]+={"adPlaybackContext":{"adType":"AD_TYPE_INSTREAM"}})
        www.youtube.com##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.attestationRequest][?.context.client.userAgent=/channel|lactmilli|instream/].playbackContext.contentPlaybackContext.lactMilliseconds="${now}")
        www.youtube.com##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.attestationRequest][?.context.client.userAgent=/adunit|channel|lactmilli|instream|inline|yahi|eafg/].playbackContext.contentPlaybackContext.referer=repl({"regex":"(?:#reloadxhr)?$"\,"replacement":"#reloadxhr"}))
        www.youtube.com##+js(nano-stb, [native code], 17000, 0.001)
        www.youtube.com##+js(json-prune-fetch-response, adPlacements adSlots playerResponse.adPlacements playerResponse.adSlots [].playerResponse.adPlacements [].playerResponse.adSlots, , propsToMatch, /\/player(\?|$)/)
        www.youtube.com##+js(json-prune-fetch-response, adPlacements adSlots playerResponse.adPlacements playerResponse.adSlots, , propsToMatch, /playlist?)
        www.youtube.com##+js(json-prune-xhr-response, adPlacements adSlots playerResponse.adPlacements playerResponse.adSlots [].playerResponse.adPlacements [].playerResponse.adSlots, , propsToMatch, /\/player(?:\?.+)?$/)
        tv.youtube.com##+js(trusted-replace-xhr-response, '"adPlacements"', '"no_ads"', /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/)
        !#if !cap_html_filtering
        www.youtube.com##+js(trusted-replace-xhr-response, /"adPlacements.*?([A-Z]"\}|"\}{2\,4})\}\]\,/, , /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/)
        www.youtube.com##+js(trusted-replace-xhr-response, /"adPlacements.*?("adSlots"|"adBreakHeartbeatParams")/gms, $1, /\/player(?:\?.+)?$/)
        www.youtube.com##+js(trusted-rpfr, '"adPlacements"', '"no_ads"', player?)
        www.youtube.com##+js(trusted-rpfr, '"adSlots"', '"no_ads"', player?)
        www.youtube.com##+js(trusted-rpfr, '"adSlots"', '"no_ads"', /^\W+$/)
        www.youtube.com##+js(rmnt, script, window\,"fetch")
        !#else
        !#endif
        www.youtube.com##+js(trusted-prevent-dom-bypass, Node.prototype.appendChild, fetch)
        www.youtube.com##+js(trusted-prevent-dom-bypass, Node.prototype.appendChild, Request)
        www.youtube.com##+js(trusted-prevent-dom-bypass, Node.prototype.appendChild, JSON.parse)
        youtube.com##+js(json-prune, entries.[-].command.reelWatchEndpoint.adClientParams.isAd)
        www.youtube.com##+js(trusted-rpfr, '"adSlots"', '"no_ads"', /get_watch?)
        tv.youtube.com##+js(trusted-replace-xhr-response, '"adPlacements"', '"no_ads"', /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/)
        !#if !cap_html_filtering
        www.youtube.com##+js(trusted-replace-xhr-response, /"adPlacements.*?([A-Z]"\}|"\}{2\,4})\}\]\,/, , /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/)
        www.youtube.com##+js(trusted-replace-xhr-response, /"adPlacements.*?("adSlots"|"adBreakHeartbeatParams")/gms, $1, /\/player(?:\?.+)?$/)
        www.youtube.com##+js(trusted-rpfr, '"adPlacements"', '"no_ads"', player?)
        www.youtube.com##+js(trusted-rpfr, '"adSlots"', '"no_ads"', player?)
        !#else
        !#endif
        m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, ytInitialPlayerResponse.playerAds, undefined)
        m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
        m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, ytInitialPlayerResponse.adSlots, undefined)
        m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, playerResponse.adPlacements, undefined)
        m.youtube.com,music.youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots important)
        m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune-fetch-response, reelWatchSequenceResponse.entries.[-].command.reelWatchEndpoint.adClientParams.isAd entries.[-].command.reelWatchEndpoint.adClientParams.isAd, , propsToMatch, url:/reel_watch_sequence?)
        m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune, entries.[-].command.reelWatchEndpoint.adClientParams.isAd)
        m.youtube.com##+js(json-edit-fetch-response, ..itemSectionRenderer.contents.*[?.adSlotRenderer], propsToMatch, /get_watch)
        """#
        let out = FilterListConverter.convert("!#trusted on\n" + rules)
        let expected = rules.split(separator: "\n").filter { $0.contains("##+js(") && !$0.contains("legacyImportant") }
        XCTAssertEqual(out.scriptlets.count, expected.count)
        XCTAssertFalse(out.scriptlets.contains { $0.args.first?.hasSuffix("legacyImportant") == true })
        XCTAssertEqual(out.scriptlets.first?.name, "replace-node-text")
        XCTAssertEqual(out.scriptlets.first?.args.suffix(6), ["sedCount", "1", "excludes", "MutationObserver", "condition", "/serverContract|js_ld/"])
        XCTAssertTrue(out.scriptlets.first?.args[2].contains(#"t=["channel","lactmilli","inline","yahi"]"#) == true,
                      "an escaped comma stays in its argument")
    }

    func testScriptletRuleParsesAndResolvesAlias() {
        let out = FilterListConverter.convert("m.youtube.com,music.youtube.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)")
        XCTAssertEqual(out.scriptlets, [FilterListConverter.ScriptletInjection(
            domains: ["m.youtube.com", "music.youtube.com"],
            name: "set-constant",
            args: ["ytInitialPlayerResponse.adPlacements", "undefined"]
        )])
    }

    func testGenericScriptletIsSkipped() {
        XCTAssertTrue(isDropped("##+js(json-prune, x)"))
    }

    func testScriptletRuleSkipsUnsupportedScriptlet() {
        XCTAssertTrue(isDropped("a.example##+js(this-scriptlet-does-not-exist, 1)"))
    }

    func testConvertPopulatesScriptlets() {
        let out = FilterListConverter.convert("""
        youtube.com##+js(json-prune, playerResponse.adPlacements adPlacements)
        youtube.com##.ad-slot
        """)
        XCTAssertEqual(out.scriptlets.count, 1)
        XCTAssertEqual(out.scriptlets.first?.name, "json-prune")
        XCTAssertEqual(out.domainCosmetic.count, 1)
    }

    func testScriptletTableGroupsAndDedups() {
        let injs = [
            FilterListConverter.ScriptletInjection(domains: ["youtube.com"], name: "json-prune", args: ["a"]),
            FilterListConverter.ScriptletInjection(domains: ["youtube.com"], name: "json-prune", args: ["a"]),
            FilterListConverter.ScriptletInjection(domains: ["youtube.com"], name: "set-constant", args: ["x", "undefined"])
        ]
        let t = FilterListConverter.scriptletTable(from: injs, exceptions: [], cap: 100)
        XCTAssertEqual(t["youtube.com"]?.count, 2)
        XCTAssertEqual(t["youtube.com"]?[0][0] as? String, "json-prune")
        XCTAssertEqual(t["youtube.com"]?[0][1] as? [String], ["a"])
    }

    func testScriptletTableRespectsCap() {
        let injs = (0..<10).map {
            FilterListConverter.ScriptletInjection(domains: ["s\($0).example"], name: "json-prune", args: [])
        }
        let t = FilterListConverter.scriptletTable(from: injs, exceptions: [], cap: 3)
        XCTAssertEqual(t.values.reduce(0) { $0 + $1.count }, 3)
    }

    func testEverySupportedScriptletIsImplemented() throws {
        let url = try XCTUnwrap(Bundle.appResourceURL("Scriptlets", extension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("/*lilo-scriptlets*/"))
        for name in FilterListConverter.supportedScriptlets {
            XCTAssertTrue(source.contains("'\(name)'"), "Scriptlets.js missing registry key for \(name)")
        }
    }

    func testProceduralRuleHasText() {
        XCTAssertEqual(
            FilterListConverter.convert("youtube.com##.post:has-text(Sponsored)").procedural,
            [FilterListConverter.DomainCosmetic(domains: ["youtube.com"], selector: ".post:has-text(Sponsored)")]
        )
    }

    func testProceduralRuleHashQuestionHash() {
        XCTAssertEqual(
            FilterListConverter.convert("a.example,b.example#?#.ad:-abp-contains(Ad)").procedural,
            [FilterListConverter.DomainCosmetic(domains: ["a.example", "b.example"], selector: ".ad:-abp-contains(Ad)")]
        )
    }

    func testProceduralRuleRejectsUnsupportedAndPlain() {
        XCTAssertTrue(isDropped("a.example##.x:min-text-length(20)"))
        XCTAssertTrue(isDropped("##.x:has-text(y)"))
        // Plain CSS, `:has(` included, stays a domain cosmetic.
        for line in ["a.example##.x:has(.y)", "a.example##.plain"] {
            let out = FilterListConverter.convert(line)
            XCTAssertTrue(out.procedural.isEmpty, "not procedural: \(line)")
            XCTAssertEqual(out.domainCosmetic.count, 1, line)
        }
    }

    func testConvertRoutesProceduralNotDomainCosmetic() {
        let out = FilterListConverter.convert("""
        youtube.com##.post:has-text(Ad)
        youtube.com##.plain-ad
        """)
        XCTAssertEqual(out.procedural.count, 1)
        XCTAssertEqual(out.procedural.first?.selector, ".post:has-text(Ad)")
        XCTAssertEqual(out.domainCosmetic.count, 1)
        XCTAssertEqual(out.domainCosmetic.first?.selector, ".plain-ad")
    }

    func testProceduralTableGroupsAndDedups() {
        let pcs = [
            FilterListConverter.DomainCosmetic(domains: ["a.example"], selector: ".x:has-text(1)"),
            FilterListConverter.DomainCosmetic(domains: ["a.example"], selector: ".x:has-text(1)"),
            FilterListConverter.DomainCosmetic(domains: ["a.example"], selector: ".y:remove()")
        ]
        let t = FilterListConverter.selectorTable(from: pcs, cap: 100)
        XCTAssertEqual(t["a.example"], [".x:has-text(1)", ".y:remove()"])
    }

    func testProceduralTableRespectsCap() {
        let pcs = (0..<5).map {
            FilterListConverter.DomainCosmetic(domains: ["s\($0).example"], selector: ".x:has-text(z)")
        }
        let t = FilterListConverter.selectorTable(from: pcs, cap: 2)
        XCTAssertEqual(t.values.reduce(0) { $0 + $1.count }, 2)
    }

    func testEveryProceduralOperatorIsImplemented() throws {
        let url = try XCTUnwrap(Bundle.appResourceURL("ProceduralCosmetics", extension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("/*lilo-procedural*/"))
        for token in FilterListConverter.proceduralSupportedTokens {
            let name = token.dropFirst().dropLast()
            XCTAssertTrue(source.contains("'\(name)'"), "ProceduralCosmetics.js missing handler for \(name)")
        }
    }

    func testConvertSeparatesBlocksAndExceptions() {
        let out = FilterListConverter.convert(
            """
            ! header
            ||ads.example^
            ||track.example^$third-party
            @@||ads.example^$domain=publisher.example
            example.com##.cosmetic-skip
            """
        )
        XCTAssertEqual(out.blocks.count, 2)
        XCTAssertEqual(out.exceptions.count, 1)
    }

    func testGenericCosmeticsSplitTokensFromComplexSelectors() {
        let generic = FilterListConverter.genericCosmetics(
            from: [".ad-banner", "#sponsored", ".ad-banner", "a[href^=\"https://ads.\"]", ".promo .inner", "#top_ad-2"],
            exceptions: [], cap: 100
        )
        XCTAssertEqual(generic.classes, ["ad-banner"])
        XCTAssertEqual(generic.ids, ["sponsored", "top_ad-2"])
        XCTAssertEqual(generic.keyed, [".inner": [".promo .inner"]])
        XCTAssertEqual(generic.cssRules.map { ($0["action"] as? [String: Any])?["selector"] as? String },
                       ["a[href^=\"https://ads.\"]"])
        let trigger = generic.cssRules[0]["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?.count, 1, "A condition would make WebKit rebuild the rule per page")
        XCTAssertEqual(trigger?["url-filter"] as? String, ".*")
    }

    func testGenericCosmeticsKeyLinkSelectorsByTheirHost() {
        let generic = FilterListConverter.genericCosmetics(
            from: [
                "a[href^=\"https://Go.Ads.example/\"]", "[href*=\".track.example/\"]", "[href=\"//cams.example/\"]",
                "div > a[href*=\"banner.example\"][href*=\"?aff=\"]", "a[href^=\"https://go.ads.example/x\"]",
                "[href*=\"/afu.php\"]", "a:not([href*=\"safe.example\"])", "link[href^=\"https://css.example/\"]"
            ],
            exceptions: [], cap: 100
        )
        XCTAssertEqual(generic.links, [
            "go.ads.example": ["a[href^=\"https://Go.Ads.example/\"]", "a[href^=\"https://go.ads.example/x\"]"],
            "track.example": ["[href*=\".track.example/\"]"],
            "cams.example": ["[href=\"//cams.example/\"]"],
            "banner.example": ["div > a[href*=\"banner.example\"][href*=\"?aff=\"]"]
        ])
        XCTAssertEqual(generic.cssRules.map { ($0["action"] as? [String: Any])?["selector"] as? String },
                       ["[href*=\"/afu.php\"]", "a:not([href*=\"safe.example\"])", "link[href^=\"https://css.example/\"]"],
                       "No host, a negation or a non-link element stays native")
    }

    func testGenericCosmeticsHonorTheCap() {
        let generic = FilterListConverter.genericCosmetics(from: [".a", "[data-ad] span", ".d"], exceptions: [], cap: 2)
        XCTAssertEqual(generic.classes, ["a"])
        XCTAssertEqual(generic.cssRules.count, 1)
    }

    /// A complex selector waits for a class or id the hidden element carries; without one it stays native.
    func testComplexGenericSelectorsAreKeyedByTheHiddenElementsToken() {
        let generic = FilterListConverter.genericCosmetics(from: [
            "div.wrapper > .ad-box[data-x]", "#sidebar .promo:not(.keep)", "aside#top-ad", "[data-ad-slot]",
            ".a, .b", "div > span", #"div[title="(x"] .promo"#, #"div[title="].fake"]"#
        ], exceptions: [], cap: 100)
        XCTAssertEqual(generic.keyed, [".ad-box": ["div.wrapper > .ad-box[data-x]"],
                                       ".promo": ["#sidebar .promo:not(.keep)", #"div[title="(x"] .promo"#],
                                       "#top-ad": ["aside#top-ad"]])
        XCTAssertEqual(generic.cssRules.compactMap { ($0["action"] as? [String: Any])?["selector"] as? String },
                       ["[data-ad-slot]", ".a, .b", "div > span", #"div[title="].fake"]"#])
    }

    /// End-to-end safety net: the converter's output must be a JSON that WebKit actually accepts and
    /// compiles. If any produced rule is malformed (bad regex, invalid field), this fails.
    @MainActor
    func testConvertedRulesCompileInWebKit() async throws {
        guard let store = WKContentRuleListStore.default() else {
            throw XCTSkip("WKContentRuleListStore unavailable")
        }
        let sample = #"""
        ||ads.example.net^
        ||syndication.example.org^$third-party
        ||ads.example.com^$script,image,domain=news.example|~good.example
        |http://tracker.example/pixel|
        /banners/*.gif
        @@||cdn.example.com^
        /^https?:\/\/[a-z\d]{3,5}\.(?:com|net)\/[\w-]+\/ad\d+\.js$/$script
        /\/x(\/y)?\.js$/$domain=a.example
        """#
        let out = FilterListConverter.convert(sample)
        var combined = out.blocks
        combined.append(contentsOf: out.exceptions)
        let data = try JSONSerialization.data(withJSONObject: combined)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let id = "fr.arouillard.lilo.test.filterlist"
        do {
            let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
            XCTAssertNotNil(list, "WebKit should compile the converted rules")
            try? await store.removeContentRuleList(forIdentifier: id)
        } catch {
            throw XCTSkip("WKContentRuleList compile unavailable in this environment: \(error)")
        }
    }
}
