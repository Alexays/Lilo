export interface IndicatorRect {
  top: number;
  left: number;
  width: number;
  height: number;
  visible: boolean;
}

/**
 * Measures both axes rather than assuming a fixed inset, as the pinned list and the unpinned scroller inset their
 * rows differently. Hidden when there is no active row (e.g. its tab is inside a collapsed folder).
 */
export function computeIndicatorRect(
  activeRowRect:
    | { top: number; left: number; width: number; height: number }
    | null,
  containerRect: { top: number; left: number },
  scrollTop: number,
): IndicatorRect {
  if (!activeRowRect) {
    return { top: 0, left: 0, width: 0, height: 0, visible: false };
  }
  return {
    top: activeRowRect.top - containerRect.top + scrollTop,
    left: activeRowRect.left - containerRect.left,
    width: activeRowRect.width,
    height: activeRowRect.height,
    visible: true,
  };
}
