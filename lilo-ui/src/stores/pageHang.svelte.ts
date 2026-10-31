// Pages whose web process stopped responding, by tab. The active tab's hang shows a card over the
// page, every hung tab an hourglass and a counter in the sidebar. A hang on the site the user just
// reloaded from the card is a repeat: the card then offers reloading with the content blocker off.

import { SvelteMap } from "svelte/reactivity";
import { on } from "../lib/bridge";
import { settingsActions, tabActions } from "../lib/bridge/actions";
import { t } from "../lib/i18n/state.svelte";
import { onSidebarApplied } from "./sidebar.svelte";
import { showUndoToast } from "./undoToast.svelte";

/** How long Wait hides the card while the page stays stuck. */
const HANG_WAIT_MS = 10_000;

type PageHang = {
	since: number;
	/** The content blocker allowlist entry for the page. */
	host: string;
	site: string;
	repeat: boolean;
	/** The card stays hidden until then (Wait). */
	hiddenUntil: number;
	/** Reloaded from the card: the card is gone, and the page answering again shows a toast. */
	reloading: boolean;
};

const hangs = new SvelteMap<string, PageHang>();
// Ticks once a second only while a page is hung: the counters and Wait's deadline read it.
let now = $state(Date.now());
let ticker: ReturnType<typeof setInterval> | null = null;
let reloadedSite = "";
let recovered = $state<{ tabId: string; seq: number } | null>(null);

export function initPageHangStore(): void {
	on("pageResponsivenessChanged", (data) => {
		if (data.responsive) {
			if (hangs.get(data.tabId)?.reloading) recovered = { tabId: data.tabId, seq: (recovered?.seq ?? 0) + 1 };
			drop(data.tabId);
			return;
		}
		const repeat = data.site !== "" && data.site === reloadedSite;
		if (!repeat) reloadedSite = "";
		now = Date.now();
		hangs.set(data.tabId, { since: now, host: data.host, site: data.site, repeat, hiddenUntil: 0, reloading: false });
		ticker ??= setInterval(() => (now = Date.now()), 1000);
	});
	// A tab closed while hung never answers again: its hang would keep the ticker running for good.
	onSidebarApplied(({ closedTabIds }) => {
		for (const tabId of closedTabIds) if (hangs.has(tabId)) drop(tabId);
	});
}

function drop(tabId: string): void {
	hangs.delete(tabId);
	if (hangs.size === 0 && ticker !== null) {
		clearInterval(ticker);
		ticker = null;
	}
}

export function getPageHang(tabId: string): PageHang | undefined {
	return hangs.get(tabId);
}

/** The hang the card shows for `tabId`: none while Wait or a reload hides it. */
export function getShownPageHang(tabId: string): PageHang | undefined {
	const hang = hangs.get(tabId);
	return hang && !hang.reloading && now >= hang.hiddenUntil ? hang : undefined;
}

/** Whole seconds `tabId` has been stuck, null when it is not. */
export function getHangSeconds(tabId: string): number | null {
	const hang = hangs.get(tabId);
	return hang ? Math.max(0, Math.floor((now - hang.since) / 1000)) : null;
}

/** Bumped when a page reloaded from the card answers again. */
export function getRecoveredPage(): { tabId: string; seq: number } | null {
	return recovered;
}

export function waitForHungPage(tabId: string): void {
	const hang = hangs.get(tabId);
	if (hang) hangs.set(tabId, { ...hang, hiddenUntil: Date.now() + HANG_WAIT_MS });
}

/** Reloads the active tab, whose hang the card shows; `withoutBlocker` first adds the site to the
 * content blocker's allowed sites and offers to undo it. */
export function reloadHungPage(tabId: string, withoutBlocker?: boolean): void {
	const hang = hangs.get(tabId);
	if (!hang) return;
	const { host } = hang;
	reloadedSite = hang.site;
	hangs.set(tabId, { ...hang, reloading: true });
	if (!withoutBlocker) return tabActions.reload();
	// Native reloads the tab once the rules leaving the site out are in place: a reload before would hang it again.
	settingsActions.toggleBlockerAllowlist(host, tabId);
	showUndoToast(t("pageHang.blockerOff", { host }), () => settingsActions.toggleBlockerAllowlist(host));
}

export function closeHungTab(tabId: string): void {
	drop(tabId);
	tabActions.close(tabId);
}
