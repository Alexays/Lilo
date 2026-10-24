// The chrome's custom scheme is not a secure context, so navigator.clipboard rejects: fall back to execCommand.
export async function copyText(text: string): Promise<boolean> {
	try {
		await navigator.clipboard.writeText(text);
		return true;
	} catch {
		return copyViaExecCommand(text);
	}
}

function copyViaExecCommand(text: string): boolean {
	const input = document.createElement("input");
	input.value = text;
	input.style.position = "absolute";
	input.style.left = "-9999px";
	input.style.top = "-9999px";
	document.body.appendChild(input);
	try {
		input.select();
		return document.execCommand("copy");
	} catch {
		return false;
	} finally {
		document.body.removeChild(input);
	}
}
