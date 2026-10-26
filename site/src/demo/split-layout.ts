import type {
  BridgeSplitLayout,
  BridgeSplitPaneFrame,
} from "../../../lilo-ui/src/lib/bridge/protocol";

const wholeFrame = { height: 1, width: 1, x: 0, y: 0 };

export const splitFrames = (
  layout: BridgeSplitLayout,
  frame = wholeFrame
): BridgeSplitPaneFrame[] => {
  if ("tabId" in layout) {
    return [{ ...frame, tabId: layout.tabId }];
  }

  const first = { ...frame };
  const second = { ...frame };

  if (layout.vertical) {
    first.height /= 2;
    second.height /= 2;
    second.y += first.height;
  } else {
    first.width /= 2;
    second.width /= 2;
    second.x += first.width;
  }

  return [
    ...splitFrames(layout.first, first),
    ...splitFrames(layout.second, second),
  ];
};

export const removePane = (
  layout: BridgeSplitLayout,
  id: string
): BridgeSplitLayout | null => {
  if ("tabId" in layout) {
    return layout.tabId === id ? null : layout;
  }

  const first = removePane(layout.first, id);
  const second = removePane(layout.second, id);

  return first && second ? { ...layout, first, second } : (first ?? second);
};

export const swapPanes = (
  layout: BridgeSplitLayout,
  firstId: string,
  secondId: string
): BridgeSplitLayout => {
  if ("tabId" in layout) {
    let id = layout.tabId;

    if (id === firstId) {
      id = secondId;
    } else if (id === secondId) {
      id = firstId;
    }

    return { tabId: id };
  }

  return {
    ...layout,
    first: swapPanes(layout.first, firstId, secondId),
    second: swapPanes(layout.second, firstId, secondId),
  };
};

export const insertPane = (
  layout: BridgeSplitLayout,
  targetId: string,
  id: string,
  vertical: boolean,
  before: boolean,
  replace = false
): BridgeSplitLayout => {
  if ("tabId" in layout) {
    if (layout.tabId !== targetId) {
      return layout;
    }

    if (replace) {
      return { tabId: id };
    }

    const incoming = { tabId: id };

    return {
      first: before ? incoming : layout,
      second: before ? layout : incoming,
      vertical,
    };
  }

  return {
    ...layout,
    first: insertPane(layout.first, targetId, id, vertical, before, replace),
    second: insertPane(layout.second, targetId, id, vertical, before, replace),
  };
};
