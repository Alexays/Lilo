// The time of day and wallpaper color that Spaces following them read; each is watched only while one is shown.

import { on } from "../lib/bridge";
import { chromeActions } from "../lib/bridge/actions";
import { dayPart, msUntilNextDayPart, type DayPart } from "../lib/spaceColor";

let _dayPart = $state<DayPart>(dayPart(new Date().getHours()));
let _wallpaperColor = $state("");

export function getDayPart(): DayPart {
	return _dayPart;
}

export function getWallpaperColor(): string {
	return _wallpaperColor;
}

/** One timer per change of day part, not a poll. Returns the cleanup. */
export function watchDayPart(): () => void {
	let timer: ReturnType<typeof setTimeout>;
	const schedule = () => {
		const now = new Date();
		_dayPart = dayPart(now.getHours());
		// A timer that slept through the boundary fires on wake, a little late, and reads the clock again.
		timer = setTimeout(schedule, msUntilNextDayPart(now) + 1000);
	};
	schedule();
	return () => clearTimeout(timer);
}

export function watchWallpaperColor(): () => void {
	chromeActions.setWallpaperColorWatch(true);
	return () => chromeActions.setWallpaperColorWatch(false);
}

export function initSpaceColorStore(): void {
	on("wallpaperColorChanged", ({ color }) => {
		_wallpaperColor = color;
	});
}
