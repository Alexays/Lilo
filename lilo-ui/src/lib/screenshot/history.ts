/** Snapshot-based undo/redo stack. Each `push` records a full immutable snapshot of editor state. */
export interface History<T> {
	current(): T;
	push(snapshot: T): void;
	undo(): T;
	redo(): T;
	canUndo(): boolean;
	canRedo(): boolean;
}

export function createHistory<T>(initial: T): History<T> {
	let stack: T[] = [initial];
	let index = 0;

	return {
		current: () => stack[index],
		push(snapshot: T) {
			stack = stack.slice(0, index + 1);
			stack.push(snapshot);
			index = stack.length - 1;
		},
		undo() {
			if (index > 0) index -= 1;
			return stack[index];
		},
		redo() {
			if (index < stack.length - 1) index += 1;
			return stack[index];
		},
		canUndo: () => index > 0,
		canRedo: () => index < stack.length - 1,
	};
}
