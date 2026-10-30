import { on, postMessage } from "../../lib/bridge";

// Loaded with the composer, not with the chrome: the listener exists before the first search it answers.
let _files = $state.raw<{ cwd: string; query: string; files: string[] }>({ cwd: "", query: "", files: [] });
let fileSearch: ReturnType<typeof setTimeout> | undefined;
on("conversationFiles", (data) => { _files = data; });

/** Asks for the project's files matching `query`, once typing pauses: `getProjectFiles` gets the answer. */
export function searchProjectFiles(cwd: string, query: string): void {
	clearTimeout(fileSearch);
	fileSearch = setTimeout(() => postMessage("searchConversationFiles", { cwd, query }), 60);
}

/** The last answer to `searchProjectFiles`, for the query it was asked with. */
export const getProjectFiles = (): { cwd: string; query: string; files: string[] } => _files;
