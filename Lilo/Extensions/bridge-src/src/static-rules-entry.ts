// Run by ExtensionBackgroundPreparer in a bare JavaScriptCore context, which rewrites an extension's
// static declarativeNetRequest rulesets into the form WebKit applies, as Lilo does for dynamic rules.
export { webKitStaticRulesets } from './shared/dnr-rules.ts';
