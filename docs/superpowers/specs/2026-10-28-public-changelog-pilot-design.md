# Public changelog pilot

The user selected the reusable capture approach from the changelog investigation and asked for implementation with three highlights and one automated capture scenario. This document records that scope.

## Intent

Give the 0.7.0 public release a short, illustrated introduction. People can read the highlights, try Peek in the website demo, and open the complete release notes. English and French receive the same treatment.

## Approaches

- Manually supplied screenshots would improve the page quickly but leave repeated media work to the maintainer.
- Reusable capture scenarios produce screenshots from the actual demo. The user chose this approach.
- Live interactive walkthroughs inside release entries would need more maintenance and runtime work.

## Pilot

The three highlights cover the website's new Peek demo, sidebar call controls, and Spanish, Simplified Chinese, Brazilian Portuguese and Russian. Copy describes shipped behavior and is edited with the Humanizer skill. Each highlight records the original release note it describes.

The pilot records real installed Lilo opening, closing and reopening a public MDN link in native Peek. It uses one six-second WebP and poster, keeping the actual browser language and appearance on both site locales. Public-page reconnaissance uses Lilo MCP; the native window capture uses computer use because MCP-controlled tabs disable native Peek. Native provenance records the installed app version/build, public source URLs and original-frame digest.

Demo-source stories retain a Playwright scenario for local example pages in English and French and both appearances. Sharp 0.35.5 is a direct development dependency for encoding both sources. The call and language highlights use text; they do not imply that the website demo simulates native calls.

## Structure

Keep Changie and its generated changelog authoritative. An optional JSON file beside the site's content holds the release's translated headline, introduction, three highlights and capture scenario. Validate its version and source notes against the corresponding release. Older releases retain their existing rendering.

Render the story inside the existing release article and shared page layout. Show the primary recording and two smaller text highlights. Put the full English release notes in a native disclosure below the story. Keep version anchors, links, dates, generated Markdown and the complete archive.

Use Astro's image pipeline for still posters and serve the animated WebP unchanged. Images have dimensions and translated alternatives. Demo-variant selection uses CSS; native media keeps its recorded appearance. Reading the story and full notes needs no JavaScript. The recording plays once when half the player is visible. Reduce Motion keeps the poster until explicit playback. A small icon over the image provides play, stop and replay with translated accessible names. Scrolling away, hiding the document or changing appearance restores the poster and cancels playback work. No live demo instance runs on the changelog page.

Each highlight can supply an optional translated action link beside its text, outside the media. The pilot keeps a quiet demo link for Peek and supplies no action for calls or languages. The recording has no footer control bar or duration label.

## Capture lifecycle

Expose capture through Make. Capture runs only for a prepared release with story metadata, outside `make validate`. Release preparation creates missing demo-source media; missing native media stops with an instruction to import reviewed window frames. Existing media stays unchanged unless replacement is explicit. Demo provenance records the checkout revision and source digest; native provenance identifies the installed app and captured frames. Rebuilding the website never updates archived media.

The native pilot capture uses installed Lilo 0.7.0 build 20. Personal tabs and account details stay outside recorded media. Adding another capture scenario, automatic editorial selection and in-app presentation remain outside this pilot.

## Verification

Test rendered English and French highlights, source/version validation, archive preservation and image availability. Exercise the disclosure and demo link in a browser, including mobile, both appearances and JavaScript disabled. Run `make site-check site-test`, the focused website browser tests and `make validate`. Capture generation is verified by running it and checking that a normal repeat leaves archived files untouched.
