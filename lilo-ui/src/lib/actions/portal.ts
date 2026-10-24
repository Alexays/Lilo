/** Moves the node into document.body, out of any clipping or containing ancestor. Svelte's scoped
 * styles still apply: the hash class rides on the node itself. */
export function portal(node: HTMLElement) {
	document.body.appendChild(node);
	return {
		destroy() {
			node.remove();
		},
	};
}
