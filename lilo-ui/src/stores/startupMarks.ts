type StartupMarkEmitter = (event: string) => void;

export function createStartupMarkRecorder(
	emit: StartupMarkEmitter,
): (event: string) => boolean {
	const emitted = new Set<string>();
	return (event: string): boolean => {
		if (emitted.has(event)) {
			return false;
		}
		emitted.add(event);
		emit(event);
		return true;
	};
}
