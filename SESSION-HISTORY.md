# Ramps Project — Session History

> Development/deployment journal split out of the main `README.md` to keep that
> file focused on setup and deploy. This is a chronological record of fixes,
> incidents, and org deployments — useful context, not deploy instructions.

## 2025-06-24 — Fix Clone Failure: Revenue Connect Transaction Isolation

**Problem:** Clone API returned 400 because one-time lines were still visible in
the ramped group at clone time. DML-based ungrouping (`update oneTimeLines` with
`QuoteLineGroupId = null`) was not committed — Revenue Connect reads committed DB
state, not uncommitted Apex DML.

**Fix applied:**
1. Replaced DML ungroup (step 2b) with a Revenue Connect `place` API call using a
   new `buildUngroupLinesPayload` helper.
2. Replaced DML regroup (step 4b) with a Revenue Connect `place` API call reusing
   the existing `buildGroupQuoteLinesPayload`.
3. Added `buildUngroupLinesPayload` — builds payload with `"QuoteLineGroupId":
   null` and `pricingPref: "Skip"`.

**Deployed:** `QuoteRampController.cls` to main org — Succeeded (Deploy ID:
`0AfHo00000yZLqIKAW`).

**Verification steps:** open a Quote with one-time + subscription products →
launch Ramp Builder, apply ramp with 2+ segments → confirm segments created with
no 400s, one-time products only in segment 1, subscription/evergreen in all
segments.

## 2026-07-06 — Cross-Project Collision: `RevConnectCallout.cls` Overwritten in Org `main`

**Problem:** A separate local project (`quote-workspace-ui-project`) deployed its
own Apex callout utility, also named `RevConnectCallout.cls`, to the shared trial
org `main`. Its version used session-id bearer auth
(`Url.getOrgDomainUrl()` / `UserInfo.getSessionId()`), incompatible with this
project's Named-Credential-based (`SelfOrgNC`) implementation. The overwrite broke
`QuoteRampController` (this project) plus `QuoteCreationController` and
`ProductSearchController` (in `quote-guided-selling-project`), whose tests failed
to compile against the wrong version.

**Fix applied:** This repo's original `RevConnectCallout.cls` +
`RevConnectCalloutTest.cls` were untouched by the incident, so they were
redeployed as-is (`sf project deploy start --target-org main`) to restore the
correct org-wide implementation.

**Verification (`sf apex run test --target-org main`):**
`RevConnectCalloutTest` — pass; `QuoteRampControllerTest` (6/6) — pass;
`ProductSearchControllerTest` (3/3) — pass. No drift vs. org for
`QuoteRampController.cls`, the `quoteRampBuilder` LWC, the `Launch_Create_Ramps`
flow, and the `Quote.Ramp_Lines` quick action.

**Open item:** org `main` has a live `RevConnectCalloutMock` class that does not
exist in this local repo — likely created in-org outside source control; reconcile
(commit here or remove) later.

## 2026-07-10 — Performance: Cut Revenue Connect Round Trips in `applyGroupRamp`

**Problem:** Applying a ramp took ~60s. `applyGroupRamp` made separate sequential
Revenue Connect `place` callouts for things that didn't need to be separate: a
per-group Uplift/Discount PATCH, a per-group SegmentType PATCH, a per-target-
segment `AddProducts` call, and a redundant "group all lines into segment 1" call
duplicating work already done by the initial `GroupAll` action.

**Fix applied (`QuoteRampController.cls`):**
1. **Merged Uplift/Discount + SegmentType propagation** — replaced
   `applySegmentUpliftDiscount` + `propagateSegmentTypeToLines` (up to 2 calls per
   group) with a single `applySegmentAttributesAcrossGroups` building ONE graph
   over every affected line across every group (setting `UnitPriceUplift` /
   `Discount` on non-one-time lines, `SegmentType` on all).
2. **Merged `AddProducts` across all target segments** — replaced the per-segment
   loop with `buildAddProductsPayloadMulti` (one graph, every target group's
   anchor + every new line, one call).
3. **Skipped the redundant initial re-group call** — `ensureSegmentOneGroup` now
   reports whether it just created the group via `GroupAll` (fresh quote) vs.
   reused an existing one; the explicit "all lines → segment 1" PATCH runs only in
   the reuse case.
4. Added `quotePatchAnchor` / `groupPatchAnchor` helpers to de-duplicate graph
   anchor JSON.
5. `QuoteRampControllerTest.cls` needed no changes; full suite re-verified (6/6).

**Before/after timing in org `main`** (two identical fresh quotes, 4 subscription
+ 2 one-time lines, 3 custom ramp segments with uplift/discount each):

| | Callouts | Elapsed |
|---|---|---|
| Original code | 14 | 63.4s |
| Optimized code | 8 | 47.7s |

~43% fewer round trips, ~25% faster wall-clock in this scenario (more
segments/attributes = bigger savings).

**Bug found during verification (pre-existing, not introduced here):** one-time
lines (e.g. "Professional Services Hourly") get duplicated into segments 2+ during
clone despite being ungrouped via a `"QuoteLineGroupId": null` PATCH. Reproduced
identically on the pre-optimization code — unrelated to this change. Matches the
Follow-up TODO (temp-group workaround) and still needs a fix.

**Test artifacts:** two "…Copy" quotes in org `main` (`0Q0Ho000001NnqIKAS`,
`0Q0Ho000001NnqNKAS`) used for A/B timing now have live 3-segment ramps — safe to
delete/reset if scratch.

## 2026-07-21 — Deployed Ramps Project to `maintwo` Org

**Objective:** Deploy all Quote Ramp Helper components to `maintwo`
(maintwo@salesforce.com, trailsignup-269936b7ffbdfe.my.salesforce.com).

**Pre-deployment:** bumped `sfdx-project.json` `sourceApiVersion` `65.0` → `67.0`;
verified auth infra already present in `maintwo` (`SelfOrgNC`, `SelfOrgOAuthEC`,
`RevCloud` Auth Provider + Connected App).

**Deployment (sequential, all ✅ Succeeded):**
1. Apex classes (`0Afbm00000ZDEc7CAH`) — `RevConnectCallout` + `QuoteRampController`
   + tests (4 classes, 3.69s)
2. LWC (`0Afbm00000ZDyv4CAD`) — `quoteRampBuilder` (5.01s)
3. Flow (`0Afbm00000ZE7qICAT`) — `Launch_Create_Ramps` (7.65s)
4. Quick Action (`0Afbm00000ZDidOCAT`) — `Quote.Ramp_Lines` (6.36s)

**Verification:** all 6 Apex tests pass; classes confirmed via Tooling API
(`RevConnectCallout` 01pbm00000PM9nrAAD, `RevConnectCalloutTest` 01pbm00000PM9nsAAD,
`QuoteRampController` 01pbm00000PM9npAAD, `QuoteRampControllerTest`
01pbm00000PM9nqAAD). 7 metadata files, ~23s total.

**Next steps for `maintwo` users:** verify Named Credential connectivity (Execute
Anonymous GET `callout:SelfOrgNC/services/data/v67.0/limits` → expect 200; 401 →
authenticate principal; 403 → add `SelfOrgOAuthEC - default` to permission set);
add the **Ramp Lines** quick action to the Quote layout; run an end-to-end ramp
test.

**Known issue (pre-existing):** one-time lines may duplicate into segments 2+
during clone despite ungrouping — temp-group workaround in development.
