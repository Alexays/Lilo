import type { BridgeSidebarTreeSection } from "../bridge/protocol";

export type DndAxis = "horizontal" | "vertical" | "grid";

type DndSection = BridgeSidebarTreeSection;

export type DndItemKind = "space" | "tab" | "folder" | "layer";

export type DndPoint = {
	x: number;
	y: number;
};

export type DndRect = {
	left: number;
	top: number;
	right: number;
	bottom: number;
	width: number;
	height: number;
};

export type DndItem = {
	id: string;
	kind: DndItemKind;
	isPrivate?: boolean;
};

export type DndItemRect = {
	id: string;
	rect: DndRect;
};

// Structured identity of a zone. Zones carry this instead of encoding it in their
// string id, so a drop target can be interpreted without parsing the id back apart.
export type DndZoneMeta = {
	section?: DndSection;
	spaceId?: string;
	parentFolderId?: string | null;
	isCollapsed?: boolean;
	// A target that would sit under a full-width preview (a dock pill, the page): the preview
	// shrinks to a chip while it is aimed there so the highlighted target stays visible.
	compactPreview?: boolean;
};

export type DndZoneSnapshot = {
	id: string;
	axis: DndAxis;
	rect: DndRect;
	items: DndItemRect[];
};

export type DndResolvedTarget = {
	zoneId: string;
	index: number;
	axis: DndAxis;
	// Stamped by the store so readers interpret the target without calling getZoneSnapshot, which re-runs getItems()
	// and re-enters whatever derived state is asking.
	zoneRect?: DndRect;
};

export type DndTargetContext = {
	point: DndPoint;
	zone: DndZoneSnapshot;
	dragSource: DndItem;
};
