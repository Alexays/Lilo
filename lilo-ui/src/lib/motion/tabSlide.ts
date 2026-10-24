import { cubicOut } from "svelte/easing";
import { MOTION } from "./timings";

interface TabSlideParams {
  /** When true the transition is a no-op (duration 0), used for drag/shadow/not-ready/reduced-motion. */
  disabled?: boolean;
  /** Defaults to the item-enter duration; pass MOTION.itemExitMs for out:. */
  duration?: number;
}

/**
 * Collapse/expand a sidebar row by height + padding + opacity (Svelte-`slide`-like).
 * Use as `in:tabSlide` / `out:tabSlide`; composes with `animate:flip` on the same node.
 */
export function tabSlide(node: Element, params: TabSlideParams = {}) {
  if (params.disabled) return { duration: 0 };

  const style = getComputedStyle(node);
  const height = parseFloat(style.height) || 0;
  const paddingTop = parseFloat(style.paddingTop) || 0;
  const paddingBottom = parseFloat(style.paddingBottom) || 0;
  const marginTop = parseFloat(style.marginTop) || 0;
  const marginBottom = parseFloat(style.marginBottom) || 0;

  return {
    duration: params.duration ?? MOTION.itemEnterMs,
    easing: cubicOut,
    css: (t: number) => `
      overflow: hidden;
      opacity: ${t};
      height: ${t * height}px;
      padding-top: ${t * paddingTop}px;
      padding-bottom: ${t * paddingBottom}px;
      margin-top: ${t * marginTop}px;
      margin-bottom: ${t * marginBottom}px;
    `,
  };
}
