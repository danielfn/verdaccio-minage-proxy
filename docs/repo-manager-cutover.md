# Runbook: repo manager cutover (remote npmjs → proxy)

Final adoption step: switch the remote/upstream npm of the cloud repository
manager (Artifactory, Nexus, …) from `https://registry.npmjs.org/` to the
endpoint of the LB in front of this proxy. From then on, **all** of the
organization's npm metadata and tarballs go through the `minAgeDays`
quarantine (4 days).

```
developers ──▶ repo manager (cloud) ──▶ LB ──▶ [verdaccio x2] ──▶ npmjs.org
               remote re-pointed ↑       basic auth    minAgeDays: 4
```

Execution belongs to **platform/ops** (repo manager access); this runbook is
the deliverable. The chain can be pre-validated with the local simulation
below (a second verdaccio acting as repo manager) without access to the real
repo manager.

## 0. Prerequisites (checklist)

- [ ] Proxy deployed and smoke green in dev (or cluster A):
      `REGISTRY_URL=<proxy-url> SERVICE_USER=… SERVICE_PASS=… ./scripts/smoke-test.sh`
      (see the [README](../README.md#quickstart-local--single-instance)).
- [ ] Service account created **per consumer** (the repo manager is one):
      `./scripts/generate-htpasswd.sh svc-<repo-manager> '<long-password>' >> conf/htpasswd`
      — bcrypt, hot-reload, no restart (rotation: see README).
- [ ] Stable LB endpoint (`http://<LB-endpoint>/` or `https://…`) and
      **bidirectional network allowlist**: egress from the repo manager (cloud)
      to the LB (internal infra) — firewall/peering per platform.
- [ ] TLS decided: if the LB exposes `https://`, the repo manager must validate
      its certificate (**never** skip TLS verify — see common rules).
- [ ] Cutover window chosen (low traffic): when the remote changes, the repo
      manager may refresh metadata aggressively against the proxy.

## 1. Remote configuration (per product)

In all cases the change is the same concept: the npm remote/upstream goes
from `https://registry.npmjs.org/` to the LB URL, authenticated with the
service account.

### Artifactory (Remote Repository, npm)

1. **Admin → Repositories → Remote → New** (or edit the existing npm remote).
2. URL: `http://<LB-endpoint>/` (or `https://<LB-endpoint>/` if the LB exposes TLS).
3. **Authentication**: `Username` / `Password` of the service account.
   Artifactory sends **Basic auth on every request** to the remote — the right
   thing for this proxy (see C9 below).
4. **LEAVE UNCHECKED** "Enable Token Authentication" towards the remote (not
   applicable: the proxy doesn't support Artifactory's Bearer token flow).
5. Save. (npm clients keep pointing at the Artifactory virtual/repository;
   they don't change.)

### Nexus Repository (npm proxy)

1. **Server administration → Repositories** → create/edit an
   **npm (proxy)**.
2. Remote storage: `http://<LB-endpoint>/`.
3. **Authentication**: `Username` / `Password` of the service account — Nexus
   sends them as Basic to the remote. Avoid "NTLM" or token authentication
   modes if the form offers them.
4. Save. (Clients keep using the Nexus group/npm registry.)

### Generic (internal cloud repo manager)

Look for the field equivalent to "upstream / remote npm registry URL" +
"credentials":

- URL: `http://<LB-endpoint>/` (or `https://…`).
- Credentials: service account user/password, sent as **Basic auth** on
  metadata and tarball GETs to the remote.

### Common rules (all products)

| Rule | Reason |
|---|---|
| **Basic auth username/password**, never `npm login`/tokens against the proxy | Tokens are signed by a per-instance secret (HA) and don't validate across instances (C9) |
| **TLS to the LB validated** if the endpoint is `https://` — no "skip verify"/"insecure" | Skip-verify opens the channel to MITM right in front of the supply-chain link |
| **Do not** re-publish/cache privately and serve as your own | Unnecessary: the proxy is read-only and the repo manager already caches on its own |
| One service account per consumer | Rotation and traceability (R3) |

## 2. Critical caveats (read before the cutover)

### C6 — the repo manager caches metadata with its own TTL

The repo manager caches packuments **with its own TTL**. Two consequences:

1. **No retroactive quarantine**: already-cached packuments keep being served
   with the old (complete) metadata until the repo manager refreshes them.
   The quarantine becomes effective for devs as the TTL converges.
2. **`latest` recalculated**: the proxy recalculates `dist-tags.latest` when
   filtering. While the repo manager serves a pre-cutover cached packument,
   its `latest` may point to a version the proxy no longer serves (the tarball
   would 404 via the proxy until the version meets the window).

**Options when cutting over** (first one recommended):

- **Purge the npm remotes' metadata cache within the cutover window**
  (before or immediately after re-pointing) — immediate convergence.
- Accept TTL convergence (devs see a "staggered" quarantine for one repo
  manager refresh cycle).

**How to force a metadata refetch per product** (also useful after a
break-glass, see below):

| Product | Where | Command/action |
|---|---|---|
| Artifactory | Remote repo → *Maintenance* | **"Zap Caches"** of the npm remote (deletes that remote's cached metadata + tarballs); for metadata only, REST: `POST /api/repo/binaries/…` depending on version — in practice, Zap the remote |
| Nexus | npm proxy repo | **"Invalidate cache"** (Admin → Repositories → select repo → Invalidate cache); or task `Repair — Rebuild npm metadata` |
| Generic | — | Equivalent "refresh/purge metadata" button/task for the remote; failing that, temporarily set the metadata TTL to 0 and force a fetch |
| Verdaccio (reference) | storage | Delete `storage/data/<pkg>/` on the node (it's only a cache; see simulation below) |

### C9 — basic auth ALWAYS, tokens never

The proxy validates **basic auth against `conf/htpasswd` on every request**
(stateless, HA-ready). Session tokens (`npm login`, Bearer) are signed by a
per-instance secret (`.verdaccio-db` in its storage) and **are not portable**
across the 2 instances behind the LB: a token issued by A doesn't validate on
B. If the repo manager offers "token authentication" towards the remote, leave
it disabled (for Artifactory, see above).

### break-glass exemptions do NOT propagate on their own

After applying an `allow` exemption ([break-glass](break-glass.md)), the proxy
serves the exempted version **immediately**, but the repo manager only
discovers it when it refreshes that packument (or with a forced fetch). If the
requester still sees 404/ETARGET through the repo manager: force a metadata
refetch (table above) or a direct `npm view <pkg>@<version>` via the repo
manager with the TTL already expired. Account for this latency in the
break-glass SLA.

## 3. Post-cutover verification (through the repo manager)

With `<rm>` = the URL devs use for the repo manager (virtual repo /
group / internal registry):

```bash
# 1. metadata flows and the control package resolves:
npm view lodash --registry=<rm>                      # → version (e.g. 4.18.1)

# 2. real install in a test project:
npm install lodash --registry=<rm>                   # → added N packages

# 3. quarantine VISIBLE through the repo manager — pick a young
#    version (<4 days; typically the latest typescript nightly):
curl -s https://registry.npmjs.org/typescript \
  | jq -r '.time | to_entries[]
             | select(.key | test("^7\\.1\\.0-dev\\."))
             | "\(.value) \(.key)"' | sort | tail
npm view typescript@<young-version> --registry=<rm>  # → E404 / ETARGET
npm view typescript@<young-version> --registry=https://registry.npmjs.org \
                                                     # → resolves (control)
```

The contrast in step 3 (404 via repo manager vs OK via direct npmjs) proves
the chain enforces the policy. If step 3 doesn't fail: probably pre-cutover
cached metadata (C6) → purge and repeat; if it still doesn't fail, the remote
isn't pointing at the proxy (check URL/creds) or the filter isn't active
(canary).

**Adapted smoke** — smoke checks 1-2 (anonymous ping/401 against the proxy)
don't apply against a repo manager with its own auth; use `SKIP_AUTH_CHECKS=1`
mode (GETs go anonymous, or with the repo manager's credentials if it requires
them):

```bash
REGISTRY_URL=<rm> SKIP_AUTH_CHECKS=1 \
  BLOCKED_PKG=typescript BLOCKED_VERSION=<young-version> \
  ./scripts/smoke-test.sh
# → checks 1-2 "skip", 3-5 ok (including the quarantine via the repo manager)
```

### Reference local simulation (empirically validated)

The intermediary→proxy chain is pre-validated without a real repo manager: a
second verdaccio (same image `6.9.2`) as the "repo manager" with an
authenticated uplink to the local proxy. Summary (full config: uplink to the
proxy with header `authorization: Basic <base64 svc:pass>`, `access: $all`,
`proxy` to that uplink, no `filters`):

```bash
docker compose up -d                                   # proxy on :4873
docker run -d --name repo-manager-sim \
  --add-host=host.docker.internal:host-gateway \       # Linux
  -p 4876:4876 -e VERDACCIO_PORT=4876 \
  -v <config-sim>:/verdaccio/conf/config.yaml:ro \
  -v repo-manager-sim-storage:/verdaccio/storage \
  verdaccio/verdaccio:6.9.2

npm view lodash --registry=http://localhost:4876                       # OK
npm view typescript@<young-version> --registry=http://localhost:4876   # 404
REGISTRY_URL=http://localhost:4876 SKIP_AUTH_CHECKS=1 \
  BLOCKED_PKG=typescript BLOCKED_VERSION=<young-version> \
  ./scripts/smoke-test.sh                                              # green
```

Note about the official image: it ignores the yaml's `listen:` (its CMD forces
`--listen` from `VERDACCIO_PORT`) — hence the `-e VERDACCIO_PORT=4876`.
Observed result (2026-08-15): lodash `4.18.1` OK via the intermediary;
`typescript@7.1.0-dev.20260813.1` (1.9 d) → `E404` via the intermediary and
OK via direct npmjs; smoke 3/3 checks + quarantine; rollback (below)
verified.

## 4. Rollback

Re-point the repo manager's remote to `https://registry.npmjs.org/` (no
credentials) and save. The proxy stays deployed but takes no traffic —
**there is no state to clean up in the proxy** (its caches are disposable and
independent).

| Aspect | Detail |
|---|---|
| Expected time | Minutes (one config change + propagation) |
| Proxy state | Nothing to revert; it can stay as is |
| Repo manager cache | Its caches are its own: filtered metadata cached during proxy operation refreshes by TTL; for **immediate** restoration of young versions, purge the remote's metadata (table in §2) |
| Risk | Minimal: back to the pre-adoption state (pure npmjs) |

**Post-rollback verification** (validated in the local simulation):
`npm view <pkg>@<young-version> --registry=<rm>` resolves again. In the
simulation, after re-pointing and restarting, the 404 persisted until purging
the intermediary's cached metadata (C6 in mirror) — documented as expected
behavior of the repo manager link, not of the proxy.

## 5. Communication to teams (template)

> **Subject**: [change] The corporate npm registry now enforces a 4-day quarantine
>
> Starting `<date>`, the repo manager (`<rm-url>`) serves npm through a proxy
> with a *minimum release age* policy: any public version published **less
> than 4 days ago** is unavailable (404 on view/install; the tarball too).
> Versions appear on their own once they meet the window — nothing needs
> re-installing.
>
> **Impact**: builds pinning very fresh `latest`/nightlies may fail for up to
> 4 days after their publication. Existing `npm audit`/lockfiles are
> unaffected.
>
> **If you urgently need a version** (e.g. a security fix): break-glass flow —
> an issue with the repo's template and security approval:
> [docs/break-glass.md](break-glass.md). Typical wait: hours.
>
> Questions: `<support-channel>`.
