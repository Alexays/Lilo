import { on } from "../lib/bridge";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { chromeActions, spaceActions } from "../lib/bridge/actions";
import { createFrameScheduler } from "../lib/motion/frameScheduler";
import { prefersReducedMotion } from "../lib/motion/reducedMotion";
import { getAgentsSpaceId, isAgentsSpaceVisible } from "./agents.svelte";
import { hasActivePanel } from "./panels.svelte";
import {
	beginSpaceTransition,
	clearSpaceTransition,
	getActiveSpaceId,
	getFocusedSpaceId,
	getPendingSpaceTransition,
	getSpaces,
	shouldAcceptSpaceReady,
} from "./spaces.svelte";

type SwipeSource = "click" | "swipe" | "ui";
type SpaceList = ReturnType<typeof getSpaces>;

// Derived so a swipe's per-frame reads reuse one list instead of filtering the spaces each frame.
const pagedSpaces = $derived.by((): SpaceList => {
	const spaces = getSpaces();
	const agentsId = getAgentsSpaceId();
	if (!agentsId || isAgentsSpaceVisible() || agentsId === getActiveSpaceId()) return spaces;
	return spaces.filter((space) => space.id !== agentsId);
});
const activePagedIndex = $derived(getSpaceIndex(getActiveSpaceId(), pagedSpaces));

/** The Spaces a swipe pages through: the Agents space only while the bar shows it, or it is open. */
export function getPagedSpaces(): SpaceList {
	return pagedSpaces;
}

type SwipeSession = {
	startIndex: number;
	committedIndex: number;
	lastTransitionId: string;
};

type PendingClickActivation = {
	targetId: string;
	transitionId: string;
	startIndex: number;
	targetIndex: number;
};

let _virtualIndex = $state(0);
let _isScrolling = false;
let pagerElement: HTMLDivElement | undefined;
let pagerWidth = 0;
let pagerResizeObserver: ResizeObserver | undefined;
let removePagerListeners: (() => void) | undefined;
let programmaticScrollTargetId: string | null = null;
const scrollFrame = createFrameScheduler();
const programmaticReleaseFrame = createFrameScheduler();
let pendingSettleTimeout: ReturnType<typeof setTimeout> | null = null;
let activeSwipeSession: SwipeSession | null = null;
let pendingClickActivation: PendingClickActivation | null = null;
let transitionSequence = 0;
let pagerSupportsScrollEnd = false;

const pagerSnapTolerance = 1;
const pagerSnapSettleTolerance = 2;
const clickActivationThreshold = 0.58;
const swipeCommitThreshold = 0.5;
const programmaticReleaseMaxFrames = 60;
const programmaticReleaseStableFrames = 2;
const settleCheckMaxAttempts = 60;

/** Native drops UI traces unless its tracing is on: off, the per-frame bridge calls are skipped. */
export let spaceTracingEnabled = false;

function traceSwipe(
	stage: string,
	extra: Partial<{
		source: SwipeSource;
		targetId: string;
		transitionId: string;
		anchorIndex: number | null;
	}> = {},
): void {
	if (!spaceTracingEnabled) return;
	chromeActions.traceSpaceSwipe({
		stage,
		source: extra.source ?? "ui",
		activeSpaceId: getActiveSpaceId(),
		focusedSpaceId: getFocusedSpaceId(),
		targetId: extra.targetId ?? "",
		transitionId:
			extra.transitionId ?? getPendingSpaceTransition()?.transitionId ?? "",
		virtualIndex: _virtualIndex,
		scrollLeft: pagerElement?.scrollLeft ?? -1,
		width: pagerWidth,
		anchorIndex: extra.anchorIndex ?? activeSwipeSession?.startIndex ?? -1,
	});
}

export function initPagerStore(): void {
	on("browserStateChanged", (data) => {
		if (!data.transitionId && !data.profileId) {
			return;
		}

		if (!shouldAcceptSpaceReady(data.changedSpaceId, data.transitionId)) {
			traceSwipe("spaceCommitRejected", {
				targetId: data.changedSpaceId,
				transitionId: data.transitionId,
				source: "ui",
			});
			return;
		}

		const shouldLockPager = programmaticScrollTargetId === data.changedSpaceId;
		traceSwipe("spaceCommitAccepted", {
			targetId: data.changedSpaceId,
			transitionId: data.transitionId,
			source: "ui",
		});
		cancelPendingClickActivation(data.changedSpaceId, data.transitionId);
		cancelPendingSettleTimeout();
		clearSpaceTransition(data.transitionId);

		if (!shouldLockPager && (_isScrolling || activeSwipeSession)) {
			updateVirtualIndex();
			if (!pagerSupportsScrollEnd) {
				scheduleSettleCheck();
			}
			return;
		}

		// A space created in the same batch has no page yet and the scroll clamps short of it:
		// the lock re-aligns frame by frame until its page is laid out.
		lockPagerToSpace(data.changedSpaceId);
		forcePagerToSpace(data.changedSpaceId);
		releaseProgrammaticScrollWhenCommitted(data.changedSpaceId);
	});

	on("spaceDeleted", () => {
		clearSpaceTransition();
		programmaticReleaseFrame.cancel();
		releaseProgrammaticScrollLock();
		schedulePagerFocusSync();
	});

	on("spacesReordered", () => {
		const focusedSpaceId = getFocusedSpaceId();
		const reorderedSpaces = getPagedSpaces();
		activeSwipeSession = null;
		pendingClickActivation = null;
		cancelPendingSettleTimeout();
		programmaticReleaseFrame.cancel();

		if (focusedSpaceId) {
			lockPagerToSpace(focusedSpaceId);
			if (pagerElement) {
				refreshPagerWidth();
				forcePagerToSpace(focusedSpaceId, reorderedSpaces);
			} else {
				const focusedIndex = getSpaceIndex(focusedSpaceId, reorderedSpaces);
				if (focusedIndex >= 0) {
					_virtualIndex = focusedIndex;
				}
			}
		} else {
			releaseProgrammaticScrollLock();
			updateVirtualIndex();
		}

		schedulePagerFocusSync(() => {
			if (!focusedSpaceId) {
				updateVirtualIndex();
				return;
			}

			forcePagerToSpace(focusedSpaceId);
			releaseProgrammaticScrollWhenCommitted(focusedSpaceId);
		}, true);
	});
}

export function applyPagerInitialState(state?: BridgeInitialStatePayload): void {
	spaceTracingEnabled = state?.tracingEnabled === true;
	schedulePagerFocusSync(syncPagerToFocus, true);
}

export function setSpacePagerElement(element?: HTMLDivElement): void {
	if (pagerElement === element) return;

	teardownPagerElement();
	pagerElement = element;

	if (!pagerElement) {
		return;
	}

	pagerSupportsScrollEnd = "onscrollend" in pagerElement;
	refreshPagerWidth();

	const handleScroll = () => {
		scrollFrame.schedule(processPagerScroll);
	};

	const handleScrollEnd = () => {
		scrollFrame.cancel();
		settlePagerAfterScroll();
	};

	pagerElement.addEventListener("scroll", handleScroll, { passive: true });
	if (pagerSupportsScrollEnd) {
		pagerElement.addEventListener("scrollend", handleScrollEnd);
	}

	// Realign the focused space on width changes instead of preserving a stale scrollLeft.
	function alignPagerScrollOnResize(state: {
		currentScrollLeft: number;
		previousWidth: number;
		nextWidth: number;
		focusedIndex: number;
	}): number {
		if (!Number.isFinite(state.nextWidth) || state.nextWidth <= 0) {
			return state.currentScrollLeft;
		}

		if (state.focusedIndex >= 0) {
			return state.focusedIndex * state.nextWidth;
		}

		if (!Number.isFinite(state.previousWidth) || state.previousWidth <= 0) {
			return state.currentScrollLeft;
		}

		return state.currentScrollLeft * (state.nextWidth / state.previousWidth);
	}

	pagerResizeObserver = new ResizeObserver(() => {
		const previousWidth = pagerWidth;
		const nextWidth = refreshPagerWidth();
		const focusedIndex = getSpaceIndex(getFocusedSpaceId());
		if (
			pagerElement &&
			previousWidth > 0 &&
			nextWidth > 0 &&
			previousWidth !== nextWidth
		) {
			const alignedScrollLeft = alignPagerScrollOnResize({
				currentScrollLeft: pagerElement.scrollLeft,
				previousWidth,
				nextWidth,
				focusedIndex,
			});

			if (Math.abs(pagerElement.scrollLeft - alignedScrollLeft) >= pagerSnapTolerance) {
				const previousScrollBehavior = pagerElement.style.scrollBehavior;
				pagerElement.style.scrollBehavior = "auto";
				pagerElement.scrollLeft = alignedScrollLeft;
				pagerElement.style.scrollBehavior = previousScrollBehavior;
				updateVirtualIndex();
			}
		}
		if (_isScrolling) return;
		syncPagerToFocus();
	});
	pagerResizeObserver.observe(pagerElement);

	removePagerListeners = () => {
		pagerElement?.removeEventListener("scroll", handleScroll);
		if (pagerSupportsScrollEnd) {
			pagerElement?.removeEventListener("scrollend", handleScrollEnd);
		}
	};

	const syncInitialFocus = () => {
		if (getFocusedSpaceId()) {
			syncPagerToFocus();
		} else {
			updateVirtualIndex();
		}
	};

	if (pagerWidth > 0) {
		syncInitialFocus();
	} else {
		requestAnimationFrame(() => {
			refreshPagerWidth();
			syncInitialFocus();
		});
	}
}

export function getSpacePagerVirtualIndex(): number {
	const activeIndex = activePagedIndex;
	return activeIndex < 0
		? 0
		: !pagerElement || pagerWidth <= 0
			? activeIndex
			: _virtualIndex;
}

export function switchSpaceAnimated(targetId: string): void {
	if (hasActivePanel()) return;

	const spaces = getPagedSpaces();
	const targetIndex = getSpaceIndex(targetId, spaces);
	if (targetIndex < 0) return;

	if (targetId === getActiveSpaceId()) {
		syncPagerToSpace(targetId, "smooth", spaces);
		return;
	}

	const startIndex = getSpaceIndex(getActiveSpaceId(), spaces);
	const transitionId = makeTransitionId();
	beginSpaceTransition(targetId, transitionId);
	traceSwipe("switchSpaceAnimated", {
		targetId,
		transitionId,
		source: "click",
	});
	pendingClickActivation = {
		targetId,
		transitionId,
		startIndex,
		targetIndex,
	};

	syncPagerToSpace(targetId, "smooth", spaces);
}

function refreshPagerWidth(): number {
	pagerWidth = Math.max(pagerElement?.clientWidth ?? 0, 0);
	return pagerWidth;
}

function isSidebarDndActive(): boolean {
	return (
		typeof document !== "undefined" &&
		document.documentElement.classList.contains("sidebar-dnd-active")
	);
}

function cancelPagerSwipeForSidebarDnd(): boolean {
	if (!isSidebarDndActive()) return false;

	activeSwipeSession = null;
	pendingClickActivation = null;
	cancelPendingSettleTimeout();
	clearSpaceTransition();
	_isScrolling = false;

	const focusedSpaceId = getFocusedSpaceId() || getActiveSpaceId();
	if (focusedSpaceId) {
		forcePagerToSpace(focusedSpaceId);
	}

	return true;
}

function processPagerScroll(): void {
	if (cancelPagerSwipeForSidebarDnd()) {
		return;
	}

	updateVirtualIndex();
	const spaces = getPagedSpaces();

	if (!pagerSupportsScrollEnd) {
		scheduleSettleCheck();
	}

	if (programmaticScrollTargetId) {
		return;
	}

	_isScrolling = true;

	if (pendingClickActivation) {
		maybeActivatePendingClick();
		return;
	}

	beginSwipeSessionIfNeeded(spaces);
	maybeCommitSwipeDuringGesture(spaces);
}

function updateVirtualIndex(): void {
	_virtualIndex =
		!pagerElement || pagerWidth <= 0 ? 0 : pagerElement.scrollLeft / pagerWidth;
}

function syncPagerToFocus(): void {
	const focusId = getFocusedSpaceId();
	if (focusId) forcePagerToSpace(focusId, getPagedSpaces());
}

function syncPagerToSpace(
	targetId: string,
	behavior: ScrollBehavior,
	spaces: SpaceList = getPagedSpaces(),
): void {
	if (!pagerElement) return;

	const targetLeft = getTargetLeftForSpace(targetId, spaces);
	if (targetLeft === null) return;

	if (Math.abs(pagerElement.scrollLeft - targetLeft) < 1) {
		updateVirtualIndex();
		return;
	}

	pagerElement.scrollTo({ left: targetLeft, behavior: prefersReducedMotion() ? "instant" : behavior });
	updateVirtualIndex();
}

function settlePagerAfterScroll(): void {
	scrollFrame.cancel();

	if (cancelPagerSwipeForSidebarDnd()) {
		return;
	}

	updateVirtualIndex();
	cancelPendingSettleTimeout();

	if (programmaticScrollTargetId) {
		releaseProgrammaticScrollWhenCommitted(programmaticScrollTargetId);
		return;
	}

	const spaces = getPagedSpaces();
	if (!isPagerNearSnapPoint(spaces)) {
		scheduleSettleCheck();
		return;
	}

	_isScrolling = false;

	if (!pagerElement || spaces.length === 0) {
		activeSwipeSession = null;
		clearSpaceTransition();
		return;
	}

	const snappedSpace = getSnappedTargetSpace(spaces);
	if (!snappedSpace) {
		activeSwipeSession = null;
		return;
	}

	// Snap exactly to the resolved page so the pager doesn't remain a couple of
	// pixels short after momentum scrolling settles.
	forcePagerToSpace(snappedSpace.id, spaces);

	if (pendingClickActivation) {
		const targetSpace = getSettledTargetSpace(
			spaces,
			pendingClickActivation.startIndex,
		);
		if (!targetSpace) {
			pendingClickActivation = null;
			syncPagerToFocus();
			return;
		}

		if (targetSpace.id === pendingClickActivation.targetId) {
			commitSpaceSwitch(
				pendingClickActivation.targetId,
				pendingClickActivation.transitionId,
				"click",
			);
			pendingClickActivation = null;
			return;
		}

		if (targetSpace.id === getActiveSpaceId()) {
			forcePagerToSpace(targetSpace.id, spaces);
			clearSpaceTransition();
			pendingClickActivation = null;
			return;
		}
	}

	if (activeSwipeSession) {
		traceSwipe("endSwipeSession", {
			targetId: snappedSpace.id,
			transitionId: activeSwipeSession.lastTransitionId,
			anchorIndex: activeSwipeSession.startIndex,
			source: "swipe",
		});

		if (snappedSpace.id !== getFocusedSpaceId()) {
			const snappedIndex = getSpaceIndex(snappedSpace.id, spaces);
			const transitionId = makeTransitionId();
			activeSwipeSession.committedIndex =
				snappedIndex >= 0 ? snappedIndex : activeSwipeSession.committedIndex;
			activeSwipeSession.lastTransitionId = transitionId;
			beginSpaceTransition(snappedSpace.id, transitionId);
			traceSwipe("commitSwipeSnap", {
				targetId: snappedSpace.id,
				transitionId,
				anchorIndex: activeSwipeSession.startIndex,
				source: "swipe",
			});
			commitSpaceSwitch(snappedSpace.id, transitionId, "swipe");
		}
	}

	activeSwipeSession = null;
}

function beginSwipeSessionIfNeeded(spaces: SpaceList): void {
	if (activeSwipeSession) {
		return;
	}

	if (spaces.length === 0) {
		return;
	}

	const focusedSpaceId = getFocusedSpaceId();
	const focusedIndex = getSpaceIndex(focusedSpaceId, spaces);
	const startIndex =
		focusedIndex >= 0 ? focusedIndex : getSnappedSpaceIndex(spaces);
	const startSpace = spaces[startIndex];

	activeSwipeSession = {
		startIndex,
		committedIndex: startIndex,
		lastTransitionId: "",
	};

	traceSwipe("beginSwipeSession", {
		targetId: startSpace?.id ?? "",
		anchorIndex: startIndex,
		source: "swipe",
	});
}

function maybeActivatePendingClick(): void {
	if (!pendingClickActivation) {
		return;
	}

	if (!hasPassedClickActivationThreshold(pendingClickActivation)) {
		return;
	}

	commitSpaceSwitch(
		pendingClickActivation.targetId,
		pendingClickActivation.transitionId,
		"click",
	);
	pendingClickActivation = null;
}

function maybeCommitSwipeDuringGesture(spaces: SpaceList): void {
	const swipeSession = activeSwipeSession;
	if (!swipeSession) {
		return;
	}

	if (spaces.length === 0) {
		return;
	}

	const committedIndex = Math.max(
		0,
		Math.min(spaces.length - 1, swipeSession.committedIndex),
	);
	let targetIndex = committedIndex;

	if (_virtualIndex >= committedIndex + swipeCommitThreshold) {
		targetIndex = Math.min(committedIndex + 1, spaces.length - 1);
	} else if (_virtualIndex <= committedIndex - swipeCommitThreshold) {
		targetIndex = Math.max(committedIndex - 1, 0);
	}

	if (targetIndex === committedIndex) {
		return;
	}

	const targetSpace = spaces[targetIndex];
	if (!targetSpace) {
		return;
	}

	const transitionId = makeTransitionId();
	swipeSession.committedIndex = targetIndex;
	swipeSession.lastTransitionId = transitionId;
	beginSpaceTransition(targetSpace.id, transitionId);
	traceSwipe("commitSwipeBoundary", {
		targetId: targetSpace.id,
		transitionId,
		anchorIndex: swipeSession.startIndex,
		source: "swipe",
	});
	commitSpaceSwitch(targetSpace.id, transitionId, "swipe");
}

function commitSpaceSwitch(
	targetId: string,
	transitionId: string,
	source: "click" | "swipe",
): void {
	if (!targetId) {
		return;
	}

	if (source === "click") {
		lockPagerToSpace(targetId);
	}

	spaceActions.switchTo(targetId, transitionId);
}

function hasPassedClickActivationThreshold(
	pending: PendingClickActivation,
): boolean {
	if (pending.startIndex < 0 || pending.targetIndex < 0) {
		return true;
	}

	const distance = pending.targetIndex - pending.startIndex;
	if (distance === 0) {
		return true;
	}

	const thresholdIndex =
		pending.startIndex + distance * clickActivationThreshold;
	return distance > 0
		? _virtualIndex >= thresholdIndex
		: _virtualIndex <= thresholdIndex;
}

function getSettledTargetSpace(
	spaces: SpaceList,
	anchorIndex?: number | null,
): SpaceList[number] | undefined {
	const snappedIndex = Math.round(_virtualIndex);
	const limitedIndex =
		anchorIndex == null
			? snappedIndex
			: Math.max(anchorIndex - 1, Math.min(anchorIndex + 1, snappedIndex));
	const clampedIndex = clampSpaceIndex(limitedIndex, spaces);
	return spaces[clampedIndex];
}

function makeTransitionId(): string {
	return `space-switch-${Date.now()}-${++transitionSequence}`;
}

function lockPagerToSpace(targetId: string): void {
	programmaticReleaseFrame.cancel();
	programmaticScrollTargetId = targetId;
}

function releaseProgrammaticScrollLock(): void {
	programmaticScrollTargetId = null;
	_isScrolling = false;
}

function releaseProgrammaticScrollWhenCommitted(
	targetId: string,
	frame = 0,
	stableFrames = 0,
): void {
	if (programmaticScrollTargetId !== targetId) return;

	if (getActiveSpaceId() !== targetId) return;

	programmaticReleaseFrame.schedule(() => {
		const spaces = getPagedSpaces();
		forcePagerToSpace(targetId, spaces);
		updateVirtualIndex();

		if (
			programmaticScrollTargetId !== targetId ||
			getActiveSpaceId() !== targetId
		) {
			return;
		}

		const aligned = isPagerAlignedWithSpace(targetId, spaces);
		const nextStableFrames = aligned ? stableFrames + 1 : 0;

		if (aligned && nextStableFrames >= programmaticReleaseStableFrames) {
			releaseProgrammaticScrollLock();
			return;
		}

		if (frame >= programmaticReleaseMaxFrames) {
			releaseProgrammaticScrollLock();
			return;
		}

		releaseProgrammaticScrollWhenCommitted(
			targetId,
			frame + 1,
			nextStableFrames,
		);
	});
}

function schedulePagerFocusSync(
	task: () => void = syncPagerToFocus,
	waitForLayout = false,
): void {
	const run = () => {
		if (pagerElement) task();
	};

	requestAnimationFrame(() => {
		if (waitForLayout) {
			requestAnimationFrame(run);
			return;
		}

		run();
	});
}

function scheduleSettleCheck(attempt = 0): void {
	cancelPendingSettleTimeout();
	pendingSettleTimeout = setTimeout(() => {
		pendingSettleTimeout = null;
		if (!pagerElement) {
			return;
		}

		const spaces = getPagedSpaces();
		if (!isPagerNearSnapPoint(spaces)) {
			if (attempt < settleCheckMaxAttempts) {
				scheduleSettleCheck(attempt + 1);
				return;
			}
			// The scroll never reached a snap point (e.g. a wedged momentum scroll):
			// force the nearest page so the check chain cannot re-arm forever.
			const snappedSpace = getSnappedTargetSpace(spaces);
			if (snappedSpace) {
				forcePagerToSpace(snappedSpace.id, spaces);
			}
		}

		settlePagerAfterScroll();
	}, 72);
}

function cancelPendingSettleTimeout(): void {
	if (pendingSettleTimeout !== null) {
		clearTimeout(pendingSettleTimeout);
	}
	pendingSettleTimeout = null;
}

function cancelPendingClickActivation(
	targetId?: string,
	transitionId?: string,
): void {
	if (
		!pendingClickActivation ||
		(targetId && pendingClickActivation.targetId !== targetId) ||
		(transitionId && pendingClickActivation.transitionId !== transitionId)
	) {
		return;
	}

	pendingClickActivation = null;
}

function getSpaceIndex(
	spaceId: string | undefined,
	spaces: SpaceList = getPagedSpaces(),
): number {
	if (!spaceId) {
		return -1;
	}

	return spaces.findIndex((space) => space.id === spaceId);
}

function clampSpaceIndex(index: number, spaces: SpaceList): number {
	return Math.max(0, Math.min(spaces.length - 1, index));
}

function getTargetLeftForSpace(
	targetId: string,
	spaces: SpaceList = getPagedSpaces(),
): number | null {
	const targetIndex = getSpaceIndex(targetId, spaces);
	return targetIndex < 0 || pagerWidth <= 0 ? null : targetIndex * pagerWidth;
}

function getSnappedSpaceIndex(spaces: SpaceList = getPagedSpaces()): number {
	return spaces.length === 0
		? 0
		: clampSpaceIndex(Math.round(_virtualIndex), spaces);
}

function getSnappedTargetSpace(
	spaces: SpaceList,
): SpaceList[number] | undefined {
	return spaces[getSnappedSpaceIndex(spaces)];
}

function isPagerNearSnapPoint(spaces: SpaceList = getPagedSpaces()): boolean {
	if (!pagerElement || pagerWidth <= 0) return true;
	const snappedLeft = getSnappedSpaceIndex(spaces) * pagerWidth;
	return (
		Math.abs(pagerElement.scrollLeft - snappedLeft) <= pagerSnapSettleTolerance
	);
}

function forcePagerToSpace(
	targetId: string,
	spaces: SpaceList = getPagedSpaces(),
): void {
	if (!pagerElement) {
		return;
	}

	const targetLeft = getTargetLeftForSpace(targetId, spaces);
	if (targetLeft === null) return;

	const previousScrollBehavior = pagerElement.style.scrollBehavior;
	pagerElement.style.scrollBehavior = "auto";

	if (Math.abs(pagerElement.scrollLeft - targetLeft) >= pagerSnapTolerance) {
		pagerElement.scrollLeft = targetLeft;
	}

	pagerElement.style.scrollBehavior = previousScrollBehavior;

	updateVirtualIndex();
}

function isPagerAlignedWithSpace(
	targetId: string,
	spaces: SpaceList = getPagedSpaces(),
): boolean {
	if (!pagerElement) return true;
	const targetLeft = getTargetLeftForSpace(targetId, spaces);
	return (
		targetLeft === null ||
		Math.abs(pagerElement.scrollLeft - targetLeft) < pagerSnapTolerance
	);
}

function teardownPagerElement(): void {
	removePagerListeners?.();
	removePagerListeners = undefined;

	if (pagerResizeObserver) {
		pagerResizeObserver.disconnect();
		pagerResizeObserver = undefined;
	}

	clearSpaceTransition();
	activeSwipeSession = null;
	pendingClickActivation = null;
	cancelPendingSettleTimeout();
	scrollFrame.cancel();
	programmaticReleaseFrame.cancel();
	releaseProgrammaticScrollLock();
	pagerSupportsScrollEnd = false;
	pagerWidth = 0;
}
