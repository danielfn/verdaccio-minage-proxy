# verdaccio-minage-proxy

A ready-to-run configuration of [Verdaccio](https://github.com/verdaccio/verdaccio) — the popular
open-source npm registry proxy — that enforces a **minimum release age** for public packages:
an artifact *immaturity policy*, also known as a *dependency cooldown*. Any npmjs.org version
younger than the quarantine window simply does not exist for whoever consumes this proxy,
neutralizing entire classes of supply-chain attacks before they reach a single developer
machine or CI runner.

To be clear about what this is: **no custom code, no fork**. It is a thin, opinionated packaging
of stock `verdaccio/verdaccio` (pinned, official Docker image) around the
[`@verdaccio/package-filter`](https://verdaccio.org/docs/configuration#package-filter) plugin
that ships bundled with Verdaccio since 6.4.0 — plus the surrounding operational tooling
(deploy manifests, CI/CD, smoke/canary scripts and runbooks) to run it safely in a corporate
environment. All credit for the filtering itself belongs to
[the Verdaccio project](https://github.com/verdaccio/verdaccio); the value here is the policy
design, the verified behavior and the batteries-included operations around it.

```
npm / CI ──▶ your artifact repo manager (optional) ──▶ Verdaccio (this config) ──▶ registry.npmjs.org
                                                            minAgeDays: 4
```

## Why this exists

Most open-source supply-chain attacks follow the same timeline: an attacker
publishes a compromised version, and the *window of opportunity* — until
detection, takedown and remediation — is typically **hours to a few days**.
[Analysis of the prominent 2024–2025 attacks](https://blog.yossarian.net/2025/11/21/We-should-all-be-using-dependency-cooldowns)
shows 8 out of 10 had windows under a week: a 7-day cooldown would have kept
the vast majority away from end users, and a 14-day cooldown all but one. It
is, in the author's words, a defense that is "free, easy, and incredibly
effective" — an 80–90% exposure reduction for near-zero cost.

The [August 2026 Shai-Hulud campaign](https://research.jfrog.com/post/shai-hulud-is-back-august/)
is the latest proof at npm scale: a worm that compromised **400+ packages /
1,700+ versions** (starting with `keyv`), harvesting npm, GitHub, cloud,
Kubernetes and Vault credentials, then self-propagating with every token it
stole. JFrog's own conclusion: customers using an **immaturity policy** were
*fully protected* — all hijacked packages were flagged in less than 24 hours,
well inside any reasonable cooldown window.

That is exactly the policy this configuration implements — centrally, for a
whole team or company — in ~40 lines of Verdaccio configuration.

## The feature vendors sell as an add-on

An immaturity policy is conceptually simple — *don't serve versions published
more recently than N* — yet the major artifact-platform vendors don't ship it
in the base product:

| Vendor | Where the feature actually lives |
|---|---|
| Sonatype | **Not in OSS Nexus**: [nexus-public#835](https://github.com/sonatype/nexus-public/issues/835) (open since Dec 2025) asks for *exactly* this at the proxy — minimum package age, a break-glass override, and a "line-in-the-sand" date freeze (all three map 1:1 to this config: `minAgeDays`, `allow`, `dateThreshold`). Commercially it's part of the **Sonatype Firewall** add-on. |
| JFrog | **Curation** add-on (immaturity policies, per JFrog's own Shai-Hulud report) — a separate license on top of Artifactory. |
| Cloudsmith | **"Cooldown policies"** are an **add-on on the top tiers only** (Ultra/Enterprise, custom pricing) — not available at all on the self-serve Core/Pro plans, where even upstream proxying itself starts at Pro ([pricing](https://cloudsmith.com/pricing)). |
| GitHub / Renovate / pnpm / uv | `cooldown`, `minimumReleaseAge`, `exclude-newer` — all **client-side and per-project**. They protect only the developers who opt in, and never cover manual installs, other package managers, or that one `npm install pkg@latest` on a laptop. |

Client-side cooldowns scale as well as your discipline does. Enforcing the
policy **centrally at the registry proxy** covers every developer, CI job and
package manager at once — including the ones that never read your security
guidelines. This repo does it with zero add-on licenses and no per-seat cost:
one small, disposable-cache service you can run anywhere Verdaccio runs.

## What the policy does

Every public version published less than 4 days ago is invisible through this
proxy: absent from packuments (full *and* abbreviated — the format `npm
install` uses), unresolvable by exact version (`npm view pkg@version` → 404),
and its tarball endpoint returns 404. `dist-tags` and `latest` are
recalculated from the surviving versions. When a version turns 4 days old it
appears on its own — filtering happens at serve time, so nothing needs
re-publishing or cache purging. All of this was verified empirically against
the pinned image.

Break-glass exceptions for genuine emergencies (a critical security patch
published yesterday) are one `allow` rule and a restart — see the
[operations](#operations) section.

## Quickstart (local / single instance)

```bash
# First service account (bcrypt; the compose file mounts ./conf/htpasswd,
# so create it BEFORE `up`). Later accounts: `>> conf/htpasswd`, hot-reloaded.
./scripts/generate-htpasswd.sh svc-registry 'a-long-password' > conf/htpasswd
docker compose up -d

# Smoke test:
curl -s -u svc-registry:a-long-password http://localhost:4873/lodash | jq '."dist-tags"'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4873/lodash   # 401 anonymous
```

> **bcrypt yes, sha512 no**: Verdaccio 6's htpasswd validator silently fails
> on `openssl passwd -6` (`$6$`) hashes — the user just appears anonymous.
> Always use `scripts/generate-htpasswd.sh`.

To use it as the npm source for another tool (your artifact repository
manager, a CI runner, plain `npm`): point the registry/remote URL at the
proxy with **basic auth** using a service account, instead of
`https://registry.npmjs.org/`. A full runbook with per-product steps
(Artifactory/Nexus/generic), verification and rollback:
**[docs/repo-manager-cutover.md](docs/repo-manager-cutover.md)**.

### Kubernetes

`deploy/k8s/` contains a kustomize base (Deployment with health probes,
pinned image, read-only config mounts, PVC for the disposable cache) and two
example overlays (`cluster-a`, `cluster-b`) — rename or adapt them to your
own environments. TLS is expected to terminate at your load balancer; the
proxy itself serves plain HTTP on port 4873.

## What the config does (summary)

| Piece | Value | Why |
|---|---|---|
| `filters.'@verdaccio/package-filter'.minAgeDays` | `4` | The policy: quarantine window |
| `packages.'**'/'@*/*'.access` | `$authenticated` | Only trusted consumers read the proxy |
| `publish`/`unpublish` | omitted | Empty list = nobody can publish (pure proxy) |
| `auth.htpasswd.max_users` | `-1` | Self-registration disabled |
| `web.enable` | `false` | No UI: machine-to-machine |
| `uplinks` | npmjs only | Single allowed public origin |
| image | pinned `6.9.2` | A floating tag = silent policy change |

## Operations

### Break-glass (urgent exceptions)

Exempting a specific package/version from the quarantine — full
request→approval→apply flow and `allow` semantics:
**[docs/break-glass.md](docs/break-glass.md)**.

- `conf/htpasswd`: changes apply **hot** (no restart).
- `conf/config.yaml` (`allow` rules, `minAgeDays`, …): requires a restart
  (a stock Verdaccio restart takes **~1.4 s**; behind a load balancer with a
  health check, effectively zero downtime).

### Canary

A scheduled workflow (every 6h) proves the quarantine still works end-to-end:
it discovers a real version younger than the window on npmjs, asserts the
proxy blocks it (resolve 404, absent from packument, tarball 404), and runs
positive controls (an old version still served, anonymous still denied).
[`scripts/canary.sh`](scripts/canary.sh) ·
[`.github/workflows/canary.yml`](.github/workflows/canary.yml)

Manual run against the local stack:

```bash
docker compose up -d
REGISTRY_URL=http://localhost:4873 SERVICE_USER=… SERVICE_PASS=… ./scripts/canary.sh
```

Failure triage: 1) is the proxy up? run the smoke test; 2) everything 404?
check storage/auth; 3) a young version is *visible*? → incident: image/plugin
regression → roll back the pinned image + open an issue.

### CI/CD (deploy)

[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) — an example
GitHub Actions pipeline: on push to `main` touching `conf/**` or `deploy/**`
(or manual dispatch) it validates (kustomize builds, policy guard, shellcheck),
rolls out with zero-downtime restarts gated by readiness probes, and runs the
smoke test afterwards. It applies two example cluster overlays in series so a
bad change can't affect both at once — trim or extend to match your
infrastructure.

Repo configuration required:

| Kind | Name | Purpose |
|---|---|---|
| secret | `KUBE_CONFIG_CLUSTER_A` / `KUBE_CONFIG_CLUSTER_B` | CI kubeconfigs (minimal service account) |
| secret | `HTPASSWD_B64` | base64 of the full `conf/htpasswd` — materialized as the K8s Secret |
| secret | `SERVICE_USER` / `SERVICE_PASS` | service account for smoke (also used by canary) |
| variable | `LB_URL` | proxy endpoint for post-deploy smoke (same value as the canary's `REGISTRY_URL`) |

Manual dispatch: Actions → deploy → Run workflow (also the path after rotating
credentials: update the `HTPASSWD_B64` secret and re-run). Rollback:
`kubectl rollout undo` on the affected cluster.

### Scaling notes

- Auth is stateless: with basic auth every request validates against the
  htpasswd file, so you can run multiple instances behind a load balancer
  without shared state. ⚠️ Avoid `npm login`-style *tokens* against the proxy
  in multi-instance setups — each instance signs tokens with its own secret,
  so a token from one won't validate on another.
- Keep one storage/cache **per instance** (Verdaccio's local storage doesn't
  support concurrent multi-instance access). The cache is disposable: losing
  it only costs re-fetching from npmjs on demand.
- [`scripts/ha-check.sh`](scripts/ha-check.sh) generates continuous client
  traffic during a restart/deploy and reports errors/latency, and can compare
  that two endpoints enforce the same policy. Procedure and criteria:
  **[docs/ha-validation.md](docs/ha-validation.md)**.

## Production hardening

1. **Network**: put the proxy behind TLS (load balancer/ingress) and restrict
   who can reach it — it's for your infrastructure, not for end users.
2. **Credentials**: one service account per consumer, periodic rotation
   (hot-reload), secrets managed by your pipeline (never commit
   `conf/htpasswd` — it's gitignored).
3. **Storage**: the cache is disposable — no backup or replication needed.
4. **Logs**: stdout (`docker logs` / cluster log collection); filter failures
   appear as `filter has failed` — alert on it (see limitations).

## Known limitations

- **Fail-open without `time`**: if a manifest ever arrives without a `time`
  field, the filter throws and Verdaccio serves the manifest UNFILTERED (it
  logs the error). npmjs.org always includes `time`, so the practical risk is
  marginal.
- Tarballs **already cached on disk** before activating/widening the policy
  are still served by direct path (they were approved when cached).
- `minAgeDays` is global; exceptions are the plugin's `allow` rules (not
  per-package-pattern).
- Brand-new packages (only version <4 days old) → whole package 404s: that's
  the intended anti-typosquatting behavior, but socialize it with teams.

## References

- [Verdaccio](https://github.com/verdaccio/verdaccio) — the registry this is
  built on; [package-filter docs](https://verdaccio.org/docs/configuration#package-filter).
- [JFrog Security Research — Major Shai Hulud campaign strikes npm again (Aug 2026)](https://research.jfrog.com/post/shai-hulud-is-back-august/) — the incident that motivates immaturity policies; Curation customers on one were fully protected.
- [We should all be using dependency cooldowns (yossarian.net)](https://blog.yossarian.net/2025/11/21/We-should-all-be-using-dependency-cooldowns) — attack-window data across 2024–2025 incidents; cooldowns stop 80–90% of them.
- [sonatype/nexus-public#835 — Add Support for Minimum Package Age](https://github.com/sonatype/nexus-public/issues/835) — the OSS feature request for exactly this, open since Dec 2025 (Sonatype sells it as the Firewall add-on).
- [pnpm `minimumReleaseAge`](https://pnpm.io/settings#minimumreleaseage) — the client-side equivalent, per-project only.
