/** True when the user has requested reduced motion, or Low Power Mode is on (global.css stills CSS motion
 * under the same class). Safe in non-DOM contexts. */
export function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true ||
      document.documentElement.classList.contains("reduced-power"))
  );
}
