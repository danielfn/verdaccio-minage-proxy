# HA validation: rolling restart without cutoff, measured from the client

> **Status: PENDING execution on the real clusters** (requires the platform
> LB). The results template is ready to fill in. The local functional
> validation of the script (no LB, 2 containers as pseudo clusters) is in the
> last section.

## What the design promises and how to verify it

The HA design (README, "Scaling notes") promises that a rolling restart —
the one that applies any policy change (`conf/config.yaml`, break-glass,
image rotation) via the
[pipeline](../.github/workflows/deploy.yml) — produces **zero visible
failures** for the repo manager: the LB drains the instance being restarted
(readiness `/-/ping`, `maxUnavailable: 0`) and the other one serves traffic.

This document turns that promise into **measurable evidence and a repeatable
procedure**, not an act of faith:

1. **Traffic mode** (`scripts/ha-check.sh`, default): simulates the repo
   manager (GET `/left-pad` with basic auth every 100 ms, 5 s timeout per
   request) during a rollout and reports total/2xx/non-2xx, p50/p95/max
   latencies and the first 10 errors with timestamps. Sequence: 10 s of
   baseline (all 2xx or abort) → trigger the restart → keep measuring until
   `DURATION` (total window). **Success criterion: 0 non-2xx.**
2. **`--compare-policy` mode**: asserts that both clusters serve **the same
   policy** by comparing presence/absence of specific versions —
   `lodash@4.17.21` (old stable) present on BOTH; 1 young version (<
   `minAgeDays`, discovered on npmjs just like
   [canary.sh](../scripts/canary.sh)) absent from BOTH.
   **Version counts are NEVER compared across instances**: each cache is
   independent and `maxage` (20 min) introduces legitimate skew
   (architecture, consistency #5).

A 502/503 during the rollout **is not a test failure**: it's a finding —
the LB isn't draining properly. It gets documented in [Findings](#findings)
with root cause and action, and the validation isn't closed without a note.

## Step-by-step procedure

Both paths measure the same thing; they differ in how the rollout is
triggered. Run the script from a machine/runner with access to the LB
endpoint (repo variable `LB_URL`).

### A. With the pipeline (recommended — the real production path)

The rollout is executed by
[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) in series
A → B gated by readiness. Manual trigger (*Actions → deploy → Run workflow*,
or `gh`):

```bash
# Terminal 1 (or a runner): the "client" that measures. DURATION must cover
# the FULL pipeline (validate + deploy A + deploy B ~ minutes):
REGISTRY_URL=<LB_URL> SERVICE_USER=svc-repo-manager SERVICE_PASS='…' \
  DURATION=900 ./scripts/ha-check.sh \
  --restart-cmd 'gh workflow run deploy.yml --ref main'

# Alternative without gh: launch the workflow from the Actions UI right
# after starting the script WITHOUT --restart-cmd (pure baseline that covers
# the rollout).
```

The `--restart-cmd` runs in the background: measurement doesn't pause while
the pipeline converges. The script waits for it to finish at the end and
reports its rc.

### B. Manual with kubectl (faster, same mechanics)

Equivalent to the [break-glass](break-glass.md) fast-path: the A → B series
with a health wait in between (names carry the overlay's namePrefix):

```bash
REGISTRY_URL=<LB_URL> SERVICE_USER=svc-repo-manager SERVICE_PASS='…' \
  DURATION=120 ./scripts/ha-check.sh \
  --restart-cmd 'kubectl rollout restart deployment/vmp-a-verdaccio && \
                  kubectl rollout status deployment/vmp-a-verdaccio && \
                  kubectl rollout restart deployment/vmp-b-verdaccio && \
                  kubectl rollout status deployment/vmp-b-verdaccio'
```

(The namespace comes from the kubeconfig context; with explicit contexts,
add `--context <cluster-a|b>` to each kubectl.)

### A vs B policy comparison (always, after the rollout)

With direct per-cluster endpoints (if they aren't reachable from the same
machine, run twice via the LB in separate windows and compare the young
version used in each):

```bash
REGISTRY_URL_A=<direct-endpoint-A> REGISTRY_URL_B=<direct-endpoint-B> \
  SERVICE_USER=svc-repo-manager SERVICE_PASS='…' \
  ./scripts/ha-check.sh --compare-policy
```

## Success criteria

| # | Criterion | How to read it in the output |
|---|---|---|
| 1 | **0 non-2xx** throughout the window (baseline included) | `VERDICT PASS — 0 non-2xx` · exit 0 |
| 2 | Clean baseline before triggering the rollout (target sanity) | `baseline OK: N requests, 0 non-2xx` |
| 3 | The restart command finished well (otherwise: inconclusive test) | `restart-cmd … (rc=0)` |
| 4 | **Identical policy** on A and B (presence/absence, not counts) | `--compare-policy` → 4 asserts PASS · exit 0 |

Any 502/503 with criterion 1 broken → finding (see below); NOT closed
without a note with root cause and action.

## Results template — real clusters (PENDING)

Copy and fill in per validation (one per relevant rollout):

```markdown
### Validation <date YYYY-MM-DD>

| Field | Value |
|---|---|
| Date | |
| Trigger | pipeline (run #…) / manual (kubectl) |
| Deployed version (image) | verdaccio/verdaccio:… |
| Commit / PR | |
| Rollout reason | policy change / break-glass / rotation / upgrade |
| DURATION | …s (baseline 10s + …s) |
| requests / 2xx / non-2xx | … / … / … |
| Latency 2xx p50/p95/max | …ms / …ms / …ms |
| Errors (timestamp + code) | (none) / paste list |
| --compare-policy | 4/4 PASS (old=…, young=…@…) |
| **Verdict** | **PASS / FAIL** |

Full ha-check output: <paste>
```

## Findings

*(Empty for now. Any 502/503 or FAIL is documented here with: what was seen,
timestamp, root cause —e.g. LB drain config, readiness probe— and the action
taken.)*

## When to repeat the validation (operational note)

- **After any platform LB change** (healthcheck config, drain, timeouts,
  pool) — the "0 non-2xx" criterion depends on the drain, which is owned by
  the platform, not by this repo.
- **After bumping the verdaccio image** (changing the `6.9.2` pin is a
  deliberate PR): repeat traffic mode + `--compare-policy`.
- **After topology changes** (replicas per cluster, new cluster).
- Optionally, on a periodic basis alongside the policy canary.

## Local evidence (functional validation of the script, no LB)

Environment: 2 containers from the same image/config as pseudo-clusters —
A = `docker compose up -d` (:4873), B = `docker run` (:4877) with the same
ro mounts of `conf/` and its own storage. Traffic measures **against A**;
there is no LB, so this validates the **script** (baseline, detection,
percentiles, report), not the LB's real drain.

**Run 1 — restart of the instance NOT serving traffic (B): no cutoff
detected (exit 0):**

```
$ REGISTRY_URL=http://localhost:4873 … DURATION=25 ./scripts/ha-check.sh \
    --restart-cmd 'docker restart ha-b'

================ ha-check: traffic report ================
target          http://localhost:4873/left-pad
window          25s (baseline 10s + 15s of measurement)
restart-cmd     docker restart ha-b (rc=0)
--------------------------------------------------------------
requests        242
2xx             242
non-2xx         0
latency 2xx     p50=81ms p95=98ms max=117ms
first errors (max 10):
  (none)
--------------------------------------------------------------
VERDICT         PASS — 0 non-2xx in 242 requests: rolling restart without cutoff (HA promise verified)
```

**Run 2 — restart of the REAL traffic target (detection demo; exit 1
expected):** `--restart-cmd 'docker compose restart verdaccio'` restarts the
instance serving the traffic. The script recorded the cutoff (~1.3 s) and
reported it with timestamps — this is what would show up if the LB drained
badly:

```
================ ha-check: traffic report ================
target          http://localhost:4873/left-pad
window          25s (baseline 10s + 15s of measurement)
restart-cmd     docker compose restart verdaccio (rc=0)
--------------------------------------------------------------
requests        243
2xx             230
non-2xx         13
latency 2xx     p50=79ms p95=95ms max=110ms
first errors (max 10):
  2026-08-15T06:51:09.921Z  HTTP 000  85 ms
  2026-08-15T06:51:10.023Z  HTTP 000  0 ms
  … (10 listed)
  … and 3 more
--------------------------------------------------------------
VERDICT         FAIL — 13 non-2xx of 243 requests visible to the client
```

**`--compare-policy` (A=:4873, B=:4877 — same `conf/` mounted on both):**

```
ha-check: young version: typescript@7.1.0-dev.20260813.1 (age 1.92d < 4d)

CHECK                                              EXPECTED   GOT      RESULT
---------------------------------------------------------------------------------------
cluster A: lodash@4.17.21 present                  present    present  PASS
cluster B: lodash@4.17.21 present                  present    present  PASS
cluster A: typescript@7.1.0-dev.20260813.1 absent  absent     absent   PASS
cluster B: typescript@7.1.0-dev.20260813.1 absent  absent     absent   PASS

ha-check: PASS — same policy on both clusters (compared by presence/absence
of specific versions; counts NOT compared due to maxage skew)
```

`shellcheck scripts/ha-check.sh` clean. Date of the local evidence:
2026-08-15.
