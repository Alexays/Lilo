import { postMessage as emit, type BridgeCommandPayloadMap } from "../../lib/bridge";

// Out of lib/bridge/actions so it loads with the agent surfaces, not in the chrome's first frame.
export const conversationActions = {
	start: (payload: BridgeCommandPayloadMap["startConversation"]): void => emit("startConversation", payload),
	send: (payload: BridgeCommandPayloadMap["sendConversationPrompt"]): void => emit("sendConversationPrompt", payload),
	cancel: (tabId: string): void => emit("cancelConversation", { tabId }),
	answer: (tabId: string, requestId: string, optionId?: string): void =>
		emit("answerConversation", optionId ? { tabId, requestId, optionId } : { tabId, requestId }),
	answerQuestion: (payload: BridgeCommandPayloadMap["answerConversationQuestion"]): void => emit("answerConversationQuestion", payload),
	setMode: (tabId: string, modeId: string): void => emit("setConversationMode", { tabId, modeId }),
	setConfig: (tabId: string, configId: string, value: string | boolean): void => emit("setConversationConfig", { tabId, configId, value }),
	show: (tabId: string, visible: boolean): void => emit("showConversation", { tabId, visible }),
	restore: (tabId: string, checkpoint: number): void => emit("restoreConversation", { tabId, checkpoint }),
	undoFile: (tabId: string, path: string, checkpoint: number): void => emit("undoConversationFile", { tabId, path, checkpoint }),
	loadCatalog: (refresh: boolean): void => emit("loadAgentCatalog", { refresh }),
	loadSummaries: (): void => emit("loadConversations"),
	chooseProject: (): void => emit("chooseConversationProject"),
	openChanges: (tabId: string): void => emit("openConversationChanges", { tabId }),
	openFile: (tabId: string, path: string, reveal: boolean): void => emit("openConversationFile", { tabId, path, reveal }),
	previewArtifact: (tabId: string, code: string, language: string): void => emit("previewConversationArtifact", { tabId, code, language }),
	authenticate: (tabId: string, methodId: string): void => emit("authenticateConversation", { tabId, methodId }),
	loadCommands: (tabId: string): void => emit("loadConversationCommands", { tabId }),
	answerSignIn: (tabId: string, text: string): void => emit("answerConversationSignIn", { tabId, text }),
	openSignInTerminal: (tabId: string): void => emit("openConversationSignInTerminal", { tabId }),
};
