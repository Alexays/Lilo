const lastWheelAt = new WeakMap<Element, number>();

/** Notes the wheel and trackpad scrolls on `el`, momentum included, so automatic scrolls can yield to them. */
export function trackUserScroll(el: Element): () => void {
  const note = (event: Event) => lastWheelAt.set(el, event.timeStamp);
  el.addEventListener("wheel", note, { passive: true });
  return () => el.removeEventListener("wheel", note);
}

/** True while the user scrolls `el` by hand: an automatic scroll then would yank the list from under them. */
export function isUserScrolling(el: Element): boolean {
  const at = lastWheelAt.get(el);
  return at !== undefined && performance.now() - at < 150;
}
