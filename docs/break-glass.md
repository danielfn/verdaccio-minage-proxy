# Runbook: break-glass (`allow` exception)

How to handle a **request** for an exception to the `minAgeDays` quarantine
(e.g. a critical security patch published 2 days ago).

## Semantics of `allow` rules

| Rule | Effect | Example |
|---|---|---|
| `scope: '@x'` | The whole scope exempt from **all** rules (incl. `minAgeDays`) | trusted first-party scopes |
| `package: 'x'` | The whole package exempt | manually verified package |
| `package: 'x'` + `versions: '<semver>'` | Only the versions in the range exempted — **surgical** | the exact version of the fix |

* `allow` takes precedence over everything (`minAgeDays`, `dateThreshold`, `block`).
* Empirically verified: exempting `typescript@7.1.0-dev.20260813.1` with a 4-day
  window takes the packument from 3792 → 3793 versions — only that one appears.

## What to know about the lifecycle (verified in PoC)

| What | Hot-reload? | Detail |
|---|---|---|
| `conf/htpasswd` (credentials) | **Yes** — immediate hot-reload, no restart | rotation without cutoff |
| `conf/config.yaml` (`filters.allow`, `minAgeDays`, …) | **No** — plugins load at boot | requires restart: **~1.4 s** per instance; rolling with 2 instances behind the LB = **no cutoff** (the `/-/ping` healthcheck pulls the instance from the pool while it restarts) |

**Auto-expiration**: an `allow` rule becomes a no-op once the version meets
`minAgeDays` (≤ 4 days) — filtering is serve-time. Cleanup can be done at any
later time, no urgency.

**Persistent effect**: with the exception applied, it is enough for the repo
manager to *request* the version once (a build, or an `npm view` through the
repo manager) for it to stay cached there. After reverting the rule, the cached
tarball keeps being served from the repo manager (the exact metadata *listing*
behavior depends on the repo manager's refresh policy).

## Recommended flow: request → approval → apply (GitOps)

This repo **is** the source of truth for policy; the PR is the audit record:

1. **Request** — an issue in this repo using the form
   [`.github/ISSUE_TEMPLATE/break-glass.md`](../.github/ISSUE_TEMPLATE/break-glass.md)
   (template below as a quick reference).
2. **Approval** — a PR adding the rule to the `allow` block of
   `conf/config.yaml` (checklist in
   [`.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md));
   review by the security owner, enforced by
   [`.github/CODEOWNERS`](../.github/CODEOWNERS) for `conf/` (see branch
   protection below).
3. **Apply** — merge → the deploy pipeline
   ([`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml))
   applies `conf/` to **both clusters** in series (A first; B only if A's
   rollout stays healthy) with rolling without cutoff, and runs the post-deploy
   smoke against the LB (or manual: see fast-path). **Rollback** if something
   goes wrong: `kubectl rollout undo deployment/vmp-a-verdaccio` — or `vmp-b-` —
   on the affected cluster.
4. **Verification** — smoke test (below) and notify the requester.
5. **Expiration** — the rule becomes a no-op once the age is met; cleanup in a
   periodic pass (or when the next PR merges).

### Emergency fast-path (without waiting for the pipeline)

```bash
# On EACH cluster (or kubectl rollout restart deployment/verdaccio):
$EDITOR conf/config.yaml     # add the allow rule
docker compose restart verdaccio   # ~1.4s; with 2 instances the LB doesn't notice the cutoff
```
…and open the PR retro-documenting it (audit mandatory even if after the fact).

### Request template (issue)

Operational version: the GitHub form at
[`.github/ISSUE_TEMPLATE/break-glass.md`](../.github/ISSUE_TEMPLATE/break-glass.md)
(select "Break-glass" when opening the issue). Quick reference of its content:

```markdown
- Package/version: <name>@<exact version>
- Reason: <e.g. CVE-2026-XXXX, critical fix in production>
- Requested window: <until YYYY-MM-DD> (automatic cleanup possible after minAgeDays)
- Requester/approver: <who requests / who approves (security owner)>
- Rule to add:
  allow:
    - package: '<name>'
      versions: '<exact version>'
```

### Post-apply smoke test

```bash
curl -s -u svc-repo-manager:<pass> http://localhost:4873/<package> \
  | jq '.versions | has("<version>")'   # true
npm view <package>@<version> --registry=http://<repo-manager>/...  # via repo manager
```

## Branch protection (one-time manual setup)

The review mechanics only exist if `main` is protected. Configure once
in Settings → Branches → Branch protection rule for `main`:

- **Require a pull request before merging** — minimum 1 approval.
- **Require review from Code Owners** — with
  [`.github/CODEOWNERS`](../.github/CODEOWNERS), `conf/**` requires
  `@mi-org/security-team` (placeholder: replace with the real team).
- **Dismiss stale pull request approvals when new commits are pushed**.
- **Require status checks to pass** — add the deploy pipeline checks
  (`.github/workflows/deploy.yml`) once they exist; until then,
  enable it right away with whatever checks are available.
- **Include administrators** — nobody bypasses the flow (the emergency
  fast-path gets documented after the fact; never via direct push to `main`).
