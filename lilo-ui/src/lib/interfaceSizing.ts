export const INTERFACE_SIZES = ["compact", "comfortable", "roomy", "spacious"] as const;
export type InterfaceSize = typeof INTERFACE_SIZES[number];

export function resolveInterfaceSize(value: unknown): InterfaceSize {
	return INTERFACE_SIZES.includes(value as InterfaceSize) ? value as InterfaceSize : "comfortable";
}

export function interfaceSizeStep(value: unknown): number {
	return INTERFACE_SIZES.indexOf(resolveInterfaceSize(value)) - 1;
}
