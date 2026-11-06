import type { APIContext } from "astro";

import { releaseFeed } from "../../../lib/release-feed";

export const GET = ({ site }: APIContext) => releaseFeed("fr", site);
