// The time of day and wallpaper that Spaces following them read; each is watched only while it is shown.

import { on } from "../lib/bridge";
import { chromeActions } from "../lib/bridge/actions";
import { dayPart, msUntilNextDayPart, type DayPart } from "../lib/spaceColor";

let _dayPart = $state<DayPart>(dayPart(new Date().getHours()));
let _wallpaperColor = $state("");
let _wallpaperThumbnail = $state("");
// The chrome and an open color picker each watch the wallpaper: native stops once neither does.
let wallpaperWatchers = 0;

export function getDayPart(): DayPart {
	return _dayPart;
}

export function getWallpaperColor(): string {
	return _wallpaperColor;
}

export function getWallpaperThumbnail(): string {
	return _wallpaperThumbnail;
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
	wallpaperWatchers += 1;
	if (wallpaperWatchers === 1) chromeActions.setWallpaperColorWatch(true);
	return () => {
		wallpaperWatchers -= 1;
		if (wallpaperWatchers === 0) chromeActions.setWallpaperColorWatch(false);
	};
}

export function initSpaceColorStore(): void {
	on("wallpaperColorChanged", ({ color, thumbnail }) => {
		_wallpaperColor = color;
		_wallpaperThumbnail = thumbnail ?? "";
	});
}
