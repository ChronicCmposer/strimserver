# strimserver -> stackctl cutover checklist

Derived from stackctl `docs/migration.md` (Appendix A and C) for the
strimserver pilot. This file is owned by strimserver; it is not part of the
stackctl repository. The old `deploy/aws/` shell pipeline stays in place and is
the rollback path until Phase 5.

Pinned deploy tool: stackctl **v0.1.2** (`97a72d1`), via `MODULE.bazel`'s
`git_override`. Operators run it through `bazel run //deploy/aws:stackctl --`.

## Project-specific mapping

| Old | New |
|---|---|
| Infra stack `strimserver` | Infra stack `strimserver-infra` |
| Operator stack `strimserver-operator` | Same name, deleted and recreated in the Phase 4 window |
| Old artifact bucket (`strimserver.cvbn.cc`) | New hard-named `<project>-artifacts-<account>-<region>` |
| EC2 Image Builder pipeline | `ENABLE_IMAGE_BUILDER=true` + the BakedImage module |
| `deploy/aws/strimserver-{infra,operator}.yaml` | Vendored canonical `deploy/stackctl-*.yaml` |
| On-box `setup_strimserver` + `deploy.sh` | stackctl bundle fetch/verify/extract + `stackctl-setup.sh` + unchanged `deploy.sh` |
| Twitch key scp'd by `setup_strimserver` | SSM SecureString `/strimserver/twitch-stream-key` read at boot |
| On-box `strim-ddns.{service,timer}` + verify unit | Retired; stackctl owns DDNS updates (`DDNS_ONBOX=false`) |
| Unversioned `releases/` history | Fresh `releases/<tag>/` history from the next tag |

Ingress mapping (slots start at 0 because the SSH rule is separate):

- `INGRESS_TCP=4000:<operator-cidr>,2222:<operator-cidr>` -- controller and
  experimental OpenSSH, both operator-restricted.
- `INGRESS_UDP=9000` -- SRT ingest, world-open by omitting a CIDR.
- Ordinary SSH (22) stays the template's conditional `SshIngress` from
  `OPERATOR_CIDR`.

## Phase checklist

### Phase 0 -- Prepare (read-only)

- [ ] Record old stack outputs, bucket names (`strimserver.cvbn.cc`), IAM
      user/profile names, and the current release/artifact layout.
- [ ] Confirm the old operator profile and that the instance profile is
      `strimserver-instance-profile`.
- [ ] Lower the DDNS record TTL in Namecheap and wait out the old TTL.
- [ ] Freeze new releases on the old pipeline.
- [ ] Store the on-box secret (manual; stackctl never writes SSM):

      aws ssm put-parameter \
        --name /strimserver/twitch-stream-key \
        --type SecureString \
        --value "<the Twitch stream key>"

- [ ] Keep the DDNS SecureString `/strimserver/ddns/password` (or create it;
      `launch`/`status` fail closed when it is missing).

### Phase 1 -- New infra stack alongside the old

- [ ] Vendored templates are present and checker-clean:

      bazel run @stackctl//deploy/check:template_check -- \
        operator "$PWD/deploy/stackctl-operator.yaml"
      bazel run @stackctl//deploy/check:template_check -- \
        infra "$PWD/deploy/stackctl-infra.yaml"

- [ ] `.env`/`.env.example` reviewed; unknown keys removed.
- [ ] Artifact bucket copied (old bucket read-only afterwards):

      aws s3 sync "s3://strimserver.cvbn.cc" \
        "s3://strimserver-artifacts-<account>-us-east-2"

- [ ] First `deploy` creates `strimserver-infra`.
- [ ] Rendered security group verified: TCP 4000 + 2222 from the operator CIDR,
      UDP 9000 world-open.

### Phase 2 -- Launch and terminate cutover

- [ ] `bazel run //deploy/aws:stackctl -- launch` succeeds; `stackctl-setup.sh`
      mounted the instance store, fetched the key, rendered
      `config/strimserver.env`, and `deploy.sh` exited 0.
- [ ] Instance carries the new project tag; DDNS points at the new IP; the
      dedicated stackctl known-hosts store is used.
- [ ] `stackctl terminate` is now the only teardown path.

### Phase 3 -- Deploy pipeline cutover

- [ ] Push an annotated `vX.Y.Z` tag and publish the first stackctl release:

      git tag -a vX.Y.Z -m "strimserver vX.Y.Z"
      git push origin vX.Y.Z
      bazel run //deploy/aws:stackctl -- deploy

- [ ] Release members: four deployment tars and `strimserver.env.template`
      (see `RELEASE_TARGETS`). Manifest verified.
- [ ] CI uses the new release prefix (`RELEASE_PREFIXES=releases/`).
- [ ] Old unversioned prefixes remain read-only.

### Phase 4 -- Operator-stack maintenance window (only IAM removal)

- [ ] Announce the window (DDNS TTL already lowered).
- [ ] `stackctl terminate` the instance.
- [ ] Delete the old `strimserver-operator` stack. Do not delete it under a
      live instance.
- [ ] `bazel run //deploy/aws:stackctl -- provision` recreates the canonical
      operator stack and refreshes `[strimserver]` credentials.
- [ ] `bazel run //deploy/aws:stackctl -- launch` again.
- [ ] Verify TLS renewal end to end before deleting old certificate data.
- [ ] Raise the DDNS TTL back to normal.

### Phase 5 -- Decommission

- [ ] Delete the old `strimserver` infra stack and retained buckets after a
      full release cycle.
- [ ] Remove the old shell entry points and old per-project templates.
- [ ] Leave old `releases/` prefixes read-only for one retention period, then
      delete them.
- [ ] Record the final state here.

## DDNS unit retirement

stackctl updates the Namecheap record on launch/terminate, so the on-box units
are no longer used. At cutover, on the box (or in the baked image):

```bash
sudo systemctl disable --now strim-ddns.timer strim-ddns.service \
  strim-ddns-verify.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/strim-ddns.service \
  /etc/systemd/system/strim-ddns.timer \
  /etc/systemd/system/strim-ddns-verify.service
sudo systemctl daemon-reload
```

Keep `ENABLE_DDNS="false"` in `core/strimserver.env.template`. The old
`deploy.sh` still honors the flag, but the stackctl path never sets it to true.

## Vendored templates

`deploy/stackctl-operator.yaml` and `deploy/stackctl-infra.yaml` are copied
verbatim from stackctl v0.1.2 (plus a source-version header comment). Re-copy
both files whenever the `git_override` pin moves, then re-run the two checker
commands above.
