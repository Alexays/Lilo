import { on } from "../lib/bridge";
import type { BridgeMeeting } from "../lib/bridge/protocol";

let _meeting = $state.raw<BridgeMeeting | null>(null);

export function initMeetingStore(): void {
	on("meetingChanged", (data) => {
		_meeting = data.meeting;
	});
}

/** The calendar event about to start that the meeting card shows. */
export const getMeeting = (): BridgeMeeting | null => _meeting;
