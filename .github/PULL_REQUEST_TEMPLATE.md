<!-- Review checklist — the PR is the audit record of the change.
     Break-glass flow: see docs/break-glass.md -->

## Type of change

- [ ] Policy (`conf/**`) — changes the proxy's behavior
- [ ] Infra (`deploy/**`) — manifests/overlays
- [ ] Docs / CI / scripts

## Break-glass (only if this PR adds or modifies `allow` rules)

- [ ] Request issue: <link to the break-glass issue>
- [ ] Approver (security owner, the one CODEOWNERS requires): <@user>

## Local validation

- [ ] `kubectl kustomize deploy/k8s/overlays/cluster-a` OK
- [ ] `kubectl kustomize deploy/k8s/overlays/cluster-b` OK

## Post-merge

- [ ] Post-deploy smoke green — run by the pipeline in both clusters;
      confirm green after the merge (see `scripts/smoke-test.sh`)
- [ ] If this PR adds `allow`: expected cleanup — the rule auto-expires upon
      reaching `minAgeDays` (4 days), note here the date of the cleanup
      sweep: YYYY-MM-DD
