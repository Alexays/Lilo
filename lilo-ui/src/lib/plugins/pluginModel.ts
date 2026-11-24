// The plugin panel's model: what the host sends, made safe to render. i18n-free like the other panel models
// (unit-tested under tsx): it exposes catalog KEYS, the components resolve them with t().
import type { BridgePluginRow, BridgePluginSettingSpec, BridgePluginSettingValue } from "../bridge/protocol";

export type PluginRow = BridgePluginRow;
export type PluginSettingSpec = BridgePluginSettingSpec;
export type PluginSettingValue = BridgePluginSettingValue;

const SETTING_TYPES: readonly PluginSettingSpec["type"][] = ["text", "password", "dropdown", "toggle", "number"];

/** Catalog keys of the capabilities the host knows; any other id shows as written. */
const CAPABILITY_LABEL_KEYS: Record<string, string> = {
	schedule: "plugins.capabilities.schedule",
	"tabs:read": "plugins.capabilities.tabsRead",
	"tabs:open": "plugins.capabilities.tabsOpen",
	"page:read": "plugins.capabilities.pageRead",
	"page:act": "plugins.capabilities.pageAct",
	"settings:store": "plugins.capabilities.settingsStore",
	"ui:surface": "plugins.capabilities.uiSurface",
	"files:plugin-dir": "plugins.capabilities.filesPluginDir",
};

export const capabilityLabelKey = (capability: string): string | undefined => CAPABILITY_LABEL_KEYS[capability];

const text = (value: unknown): string => (typeof value === "string" ? value : "");
const textList = (value: unknown): string[] => (Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : []);

// Icons render as <img src>: only data:image/ URLs from the host are trusted, like the extensions' icons.
const iconURL = (value: unknown): string | undefined => (typeof value === "string" && /^data:image\//i.test(value) ? value : undefined);

function coerceSpec(raw: Partial<PluginSettingSpec> | null | undefined): PluginSettingSpec | null {
	const name = text(raw?.name);
	const type = raw?.type;
	if (!name || !type || !SETTING_TYPES.includes(type)) return null;
	return {
		name,
		type,
		title: text(raw?.title) || name,
		...(type === "dropdown" ? { options: textList(raw?.options) } : {}),
		...(raw?.default !== undefined ? { default: raw.default } : {}),
		...(raw?.required ? { required: true } : {}),
	};
}

/** One row of a `pluginsChanged` payload, or null for a row with no id. */
export function coercePluginRow(raw: Partial<PluginRow> | null | undefined): PluginRow | null {
	const id = text(raw?.id);
	if (!id) return null;
	const rejectionReason = text(raw?.rejectionReason);
	const settingValues: PluginRow["settingValues"] = {};
	for (const [name, value] of Object.entries(raw?.settingValues ?? {})) {
		if (["string", "number", "boolean"].includes(typeof value)) settingValues[name] = value;
	}
	return {
		id,
		title: text(raw?.title) || id,
		version: text(raw?.version),
		icon: iconURL(raw?.icon),
		enabled: raw?.enabled === true && !rejectionReason,
		running: raw?.running === true,
		...(rejectionReason ? { rejectionReason } : {}),
		capabilities: textList(raw?.capabilities),
		grantedCapabilities: textList(raw?.grantedCapabilities),
		settings: (Array.isArray(raw?.settings) ? raw.settings : []).map(coerceSpec).filter((spec) => spec !== null),
		settingValues,
		supportDir: text(raw?.supportDir),
	};
}

/** The current value of a setting: what the user set, else the manifest's default, else the type's empty value. */
export function settingValue(row: PluginRow, spec: PluginSettingSpec): PluginSettingValue {
	const stored = row.settingValues[spec.name];
	if (stored !== undefined) return stored;
	if (spec.default !== undefined) return spec.default;
	switch (spec.type) {
		case "toggle":
			return false;
		case "dropdown":
			return spec.options?.[0] ?? "";
		default:
			return "";
	}
}

/** What a field commits for the text it holds: a number field sends a number, an empty one nothing. */
export function parseSettingInput(spec: PluginSettingSpec, input: string): PluginSettingValue | null {
	if (spec.type !== "number") return input;
	const trimmed = input.trim();
	if (!trimmed) return null;
	const value = Number(trimmed);
	return Number.isFinite(value) ? value : null;
}

/** A required setting still holding nothing: the plugin cannot run until the user fills it in. */
export function missingRequiredSettings(row: PluginRow): PluginSettingSpec[] {
	return row.settings.filter((spec) => {
		if (!spec.required || spec.type === "toggle") return false;
		const value = settingValue(row, spec);
		return value === "" || (typeof value === "string" && !value.trim());
	});
}

/** Asked for and not granted: enabling shows these once before the plugin runs. */
export const ungrantedCapabilities = (row: PluginRow): string[] =>
	row.capabilities.filter((capability) => !row.grantedCapabilities.includes(capability));

export type PluginStatus = "rejected" | "running" | "enabled" | "disabled";

export function pluginStatus(row: PluginRow): PluginStatus {
	if (row.rejectionReason) return "rejected";
	if (!row.enabled) return "disabled";
	return row.running ? "running" : "enabled";
}

/** The plugin's initial for the tile, when it ships no icon. */
export const pluginInitial = (row: PluginRow): string => Array.from(row.title.trim())[0]?.toUpperCase() ?? "?";
