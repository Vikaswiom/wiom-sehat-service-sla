# सेहत गारंटी — Service SLA cohort

Second public deployment of **Sehat MG** for the **Service-SLA campaign** (Track B — "फिट रखना").
Point the Service cohort's CleverTap campaign at this URL; point the Optical cohort at the sibling
[wiom-sehat-mg](https://vikaswiom.github.io/wiom-sehat-mg/).

**Live:** https://vikaswiom.github.io/wiom-sehat-service-sla/?cspId=a0b7g3  *(a Track-B example, SLA 16%)*

## Why a second link

Each CSP is on **exactly one track**, so the screen is **track-aware**: it reads the CSP's data and
shows the one metric that decides their ₹10,000 — **समय पर समाधान (Service SLA)** for Track B, Optical
Power for Track A. This deployment is identical to the sibling on purpose:

- Point the **Service campaign** here and the **Optical campaign** at the sibling — clean per-campaign
  URLs and analytics.
- Because both links are track-aware, a CSP **always sees their correct metric** even if a cohort list
  is slightly off. No CSP is ever shown a metric that doesn't decide their money.

CleverTap token form (same as the sibling):

```
https://vikaswiom.github.io/wiom-sehat-service-sla/?cspId={{Profile.cspid}}
```

## What a Service-SLA CSP sees

- **समय पर समाधान %** vs the 80% line — e.g. `82 शिकायत · 168 चार घंटे में बंद, 26 देर से = 87%`
- Today's action: close every complaint inside the **4-hour** SLA; mark it closed in the app
- The delay note (60-day average, moves slowly) and the ₹10,000 guarantee card, graded on the
  **last 15 days** of the month (§5)
- Education (समझ लीजिए) — what the SLA is, what 80% means, how to fix service, why they got this

## Code & data

Same codebase as [wiom-sehat-mg](https://github.com/Vikaswiom/wiom-sehat-mg) — see that repo's README
for the full data map, formulas, and open decisions. `index.html`, `404.html`, and `data.json` here are
kept in sync by that repo's `refresh.py` (it copies them into this folder on every run; then commit &
push this repo too).
