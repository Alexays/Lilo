import { on } from "../lib/bridge";

/** Chrome overlays anchored to the content's right edge stop at the extension side panel. */
export function initSidePanelStore(): void {
	on("sidePanelWidthChanged", ({ width }) => {
		const style = document.documentElement.style;
		if (width > 0) style.setProperty("--side-panel-width", `${width}px`);
		else style.removeProperty("--side-panel-width");
	});
}
