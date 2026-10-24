import { on } from "../lib/bridge";

// Constrained-power signal from the native side (Low Power Mode or thermal pressure).
// The `reduced-power` root class drives global CSS that drops backdrop blur and
// decorative animations: pure energy cost when the machine is already struggling.
let _constrained = $state(false);

export function initPowerStore(): void {
	on("powerModeChanged", (data) => {
		_constrained = Boolean(data?.constrained);
		if (typeof document !== "undefined") {
			document.documentElement.classList.toggle("reduced-power", _constrained);
		}
	});
	// The system "Reduce transparency" setting drops the same blur, for legibility instead of energy.
	on("reduceTransparencyChanged", (data) => {
		document.documentElement.classList.toggle("reduced-transparency", Boolean(data?.reduce));
	});
}
