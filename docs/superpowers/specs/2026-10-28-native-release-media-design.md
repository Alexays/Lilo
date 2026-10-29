# Native release media proof

The user selected autonomous native demonstrations and authorized implementing the first proof with Peek and the 0.8.0 address-bar and tab-sharing features. Failed quality checks must block release preparation; there is no poster fallback for a required recording.

## Outcome

Generate three smooth recordings of the real compiled Lilo UI in an isolated native test host. Capture continuous window frames, preserve their timestamps, and encode animated WebP plus a still poster. An agent selects the most important supported features from the prepared release notes and produces a validated capture plan. The proof has three reusable native scenarios; automatic creation of arbitrary future native scenarios is a later milestone, and unsupported selections must fail explicitly.

## Approaches

The website demo cannot exercise every native feature. Manually maintained scenarios alone do not meet the user's zero-work release requirement. The chosen approach combines agent selection and direction with native execution and automatic quality checks. For this first proof, existing production entry points and real page interaction drive three known scenarios in XCTest; no recording or automation code enters the shipped browser.

## Constraints and decisions

- Preserve historical 0.7.0 media. Peek is recorded honestly with the current 0.8.0 build as a proof, not attributed to an old binary.
- Run only through Make, separately from ordinary validation. Capture only the test host's window with ScreenCaptureKit. Use temporary browser storage and made-up page content.
- Render the production chrome and native Peek; tab sharing uses the real picker and frame-ferry session. Assertions verify results.
- Record at 30 fps with actual media timestamps. Bounded frame encoding, duration, geometry, motion, and semantic assertions are required gates. Record a quality report and source provenance; never claim subjective visual judgment is mechanically guaranteed.
- Generate files in a staging directory. Publish the complete archive only after every selected scenario passes. Existing reviewed archives require explicit replacement.
- A release media check fails closed for missing, incomplete, failed, mismatched, or modified recordings. Final release packaging checks this before signing.
- Keep media binary resources separate from the text-only chrome embed. Website and in-app consumers use the same capture archive, with local bundled assets in the app and no runtime network fetch.
- Keep the approved compact changelog layout, translated controls, keyboard access, Reduce Motion, one playback, cleanup on hidden/closed views, and zero idle capture work.
- The first proof may require a GUI-capable macOS worker. Permission failure is a real failure, never a simulated recording.

## Verification

Run the three native scenarios and inspect their actual outputs, exercise deliberate quality failures, verify both consumers and offline app resources, then run make validate and focused browser checks. Native capture does not run during make validate. Report any infrastructure limitation precisely.
