# PR #149 review guide

PR #149 is replaced by five PRs. Review them in order. Each child targets its parent branch so its diff contains one review unit.

**PR #156 has a known prerequisite.** Current main already contains pending 0.15.0 notes for new WebKit engine UI without a native capture recipe. The original refusal is preserved. Global authoring CI and that feature release remain blocked until genuine capture coverage is added. PRs #152 through #155 can be reviewed and landed separately.

| Order | PR | Focus | Start here |
| --- | --- | --- | --- |
| 1 | [#152](https://github.com/Alexays/Lilo/pull/152) | Automatic PiP cancellation. Three files. | `MediaControl.swift` and its delayed-response test. |
| 2 | [#153](https://github.com/Alexays/Lilo/pull/153) | Shared playback and one approved film. | Native byte ranges, both `ReleaseMedia` components, then staging. |
| 3 | [#154](https://github.com/Alexays/Lilo/pull/154) | Optional 0.8.0 production tools. | `pipeline.mjs`, `author.mjs`, `render.mjs`, `check.mjs`, then native capture. |
| 4 | [#155](https://github.com/Alexays/Lilo/pull/155) | Historical backfill and legacy retirement. | The catalog, added capture cases and archive recipes. Assets have bound source receipts. |
| 5 | [#156](https://github.com/Alexays/Lilo/pull/156) | Release policy and deployment wiring. | `release.yml`, Make prerequisites, then `release.py` and its tests. |

## Advance the stack

Merge the first PR into main. Then retarget the next PR to main before merging it. Repeat in order. Do not merge a child into its parent branch.

Merge commits preserve the stack ancestry. If a parent is squash-merged or rebase-merged, rebase the next branch onto the resulting main commit before retargeting it. The repository automatically deletes merged branches, so check the next PR's base after each merge.

The existing workflow triggers hosted PR checks only for a main base. Children have local verification now. Retargeting each child to main enables its hosted checks. PR #156's unsupported pending-feature refusal is documented above. No automatic merge is enabled.

## What the audit proves

The frozen original split passes 884 assertions. Its final Git tree exactly matches the reviewed PR #149 implementation at `41d8db0d9c09bff20981a9b10839634bd5fa6b36`. All 273 original changed paths survive. The temporary Playwright configuration change is restored when the backfill arrives.

The integrated split passes 1,031 assertions against main `196d1c7c06bc23ab1b833341eb0612454d548497`. Every stage matches an independently calculated merge of its frozen split tip and main. All 321 paths changed only on main remain exact. The 23 overlapping paths follow that merge, with exact reviewed adaptations for Make dependencies, optional capture stores, two new text-only decisions and archive counts.

The audit verifies every file's bytes, mode and object type. It also checks the parent chain, stage boundaries, legacy presentation until replacement, actual recipe/native/media hashes and complete quality receipt chains. There are no whole-file Swift exceptions. A missing-main negative control and a collapsed-stack negative control both fail.

The approved 0.8.0 film and poster remain byte-identical throughout PRs #153 through #156. The archive has eight films, six screenshots and nineteen text-only decisions across 33 releases. Historical receipts retain their actual source app version and commit.

## Validation

| PR | Completed checks |
| --- | --- |
| #152 | Full `make validate TEST_WORKERS=4` on integrated main. |
| #153 | Full validation, 21 app browser cases, 18 website browser cases, staging and generated project checks. Existing 0.7 recording and native artwork remain. |
| #154 | Actual native tab-share/address captures, actual bundled MP4 playback, real render/check/inspection, 70 tooling tests and publication checks. Validation used the native capture-suite filter. |
| #155 | Every historical native capture scenario on the compiled app, 73 tooling tests, fourteen publication checks, 21 app and 23 website browser cases. Validation used the native capture-suite filter. |
| #156 | Validation with the capture-suite filter, 26 release tests, 73 media tests, fourteen publication checks, prepared-tag checks and selected authoring for 0.14.3, plus a Cloudflare deployment dry run. Global authoring intentionally refuses pending 0.15.0. |

The capture suite is opt-in. The explicit capture/review commands exercised it; normal validation skips those live cases. Production Swift changes received the full native suites in the first two PRs. Later PRs compile the same app and check the added capture tools, interface changes and release behavior.

No tag was created. No signing, notarization, release publication or deployment ran. Cloudflare credentials and deployment ownership still need the documented release setup before PR #156 can publish anything.

Machine-readable results are in `validation.json`, `original-stack.json` and `integrated-stack.json`. `ownership.tsv` maps the original 273 changed paths to review units. Raw local logs and fresh smoke captures are excluded from this guide.

## Rerun the content audit

Open this guide from the separate `codex/pr149-review-guide` branch in a clean clone with Python 3 available. Its history contains all recorded tips. The audit commands inspect immutable Git objects and use a temporary repository. They do not switch the checkout or change its index.

```sh
python3 docs/reviews/pr149-split/audit_stack.py --repo . \
  --base 19c79b7e --final 41d8db0d \
  c22517f7 d0c6e11a 9d5783ee ee35e79b 43d004b

python3 docs/reviews/pr149-split/audit_integrated.py --repo . \
  --main 196d1c7c06bc23ab1b833341eb0612454d548497 \
  43b7cad3 6180105e a6bd513d 7c7c4e84 cc119f39
```

These commands reproduce the recorded snapshots. To audit later revisions, pass their five tips instead. The scripts fail when source no longer matches the recorded review.

Sequence Work into Verifiable Units shaped the base chain and checks. Build the Lever produced these audit scripts. Separate Before Serializing Shared State kept concurrent edits in separate worktrees while one checkout ran native verification.
