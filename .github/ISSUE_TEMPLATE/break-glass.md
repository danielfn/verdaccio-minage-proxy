---
name: Break-glass — quarantine exception (allow)
description: Request an exemption for a specific package/version from the minAgeDays policy (flow in docs/break-glass.md)
title: '[break-glass] <package>@<version>'
labels: ['break-glass']
body:
  - type: markdown
    attributes:
      value: |
        ## Break-glass exception request

        This issue starts the flow of `docs/break-glass.md`:
        **request** (this issue) → **PR** adding the `allow` rule in
        `conf/config.yaml` (checklist in `.github/PULL_REQUEST_TEMPLATE.md`) →
        security **review** (required by `.github/CODEOWNERS` for `conf/`) →
        **merge** → the pipeline applies to both clusters and runs the smoke test.

        The rule auto-expires when the version reaches `minAgeDays` (4 days);
        the requested window only bounds the cleanup.

  - type: input
    id: package-version
    attributes:
      label: Exact package and version
      description: Full version, no ranges — the exception must be surgical.
      placeholder: typescript@7.1.0
    validations:
      required: true

  - type: textarea
    id: reason
    attributes:
      label: Reason
      description: E.g. a CVE with a critical fix for production; link to the advisory/changelog if one exists.
      placeholder: |
        CVE-2026-XXXX (CVSS 9.8) — fix published 2 days ago, blocks patching production.
        Advisory: https://...
    validations:
      required: true

  - type: input
    id: window-until
    attributes:
      label: Requested window (until)
      description: 'YYYY-MM-DD date until which the exception is needed. The rule auto-expires upon reaching minAgeDays; this date guides the cleanup.'
      placeholder: '2026-08-20'
    validations:
      required: true

  - type: input
    id: requester
    attributes:
      label: Requester
      description: User or team requesting the exception.
      placeholder: '@user-or-team'
    validations:
      required: true

  - type: input
    id: approver
    attributes:
      label: Proposed approver (security owner)
      description: Must match the PR review that CODEOWNERS requires for conf/ (e.g. @mi-org/security-team).
      placeholder: '@mi-org/security-team'
    validations:
      required: true

  - type: textarea
    id: rule
    attributes:
      label: Rule to add in conf/config.yaml
      description: 'It gets merged under `filters.''@verdaccio/package-filter''`. Replace the <name> and <exact version> placeholders.'
      value: |
        allow:
          - package: '<name>'
            versions: '<exact version>'
      render: yaml
    validations:
      required: true

  - type: checkboxes
    id: verification
    attributes:
      label: Requester verification
      description: The exception bypasses the supply-chain quarantine; the requester takes on verifying the version.
      options:
        - label: I have verified the exact version (tarball checksum and/or provenance/review of the change that motivates it)
          required: true
        - label: I have checked that today the version is invisible via the proxy (404 due to minAgeDays) and visible on npmjs.org
          required: false
