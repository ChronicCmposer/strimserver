# strimserver -> stackctl cutover checklist

Derived from stackctl `docs/migration.md` (Appendix A and C) for the
strimserver pilot. This file is owned by strimserver; it is not part of the
stackctl repository. The old `deploy/aws/` shell pipeline stays in place and is
the rollback path until the final phase.

Pinned deploy tool: stackctl **v0.2.0** (`34badac`), via `MODULE.bazel`'s
`git_override`. Operators run it through `bazel run //deploy/aws:stackctl --`.

## Upgrading to v0.2.0

stackctl **v0.2.0** (commit `34badac`) is a breaking release for this project:
it replaces the CI prefix list with an explicit boolean, removes the
`ReleasePrefixes` CloudFormation parameter, and changes the S3 grant model for
the operator and CI users. Re-vendor the templates and re-run `provision` as
described below.

### Pin

- `MODULE.bazel`: `bazel_dep(name = "stackctl", version = "0.2.0")` with
  `git_override(commit = "34badacf99bf69e7fc772126561df5d4003e339f")`; the
  remote stays `https://github.com/ChronicCmposer/stackctl.git`.

### `ENABLE_CI_USER` replaces the CI prefix list

- `ENABLE_CI_USER` is a **required boolean** (`true` or `false`); any other
  value is rejected.
- The CI user exists iff `ENABLE_CI_USER` is true in the **any-true union**
  across the active `.env` and all `.env.*` siblings (the same merge as
  `ENABLE_IMAGE_BUILDER`). Clearing it in one file does not disable CI while a
  sibling still sets it true.
- When enabled, the CI user is a **read-only reader**: `s3:GetObject` on
  `arn:aws:s3:::${ProjectName}-artifacts-${AWS::AccountId}-*/*` and
  `s3:ListBucket` on the bucket ARN — no writes (`PutObject`/`DeleteObject`).

### S3 grant model

- The operator user now has **bucket-wide** access on the project artifacts
  bucket: `GetObject`, `PutObject`, and `DeleteObject` on
  `arn:aws:s3:::${ProjectName}-artifacts-${AWS::AccountId}-*/*`, plus an
  unconditioned `ListBucket` on the bucket ARN. The old `releases/*`-scoped
  grants are gone.

### Removed config key and parameter

- The legacy CI prefix-list key is removed in v0.2.0. A config that still
  contains it fails closed with exactly this stackctl error:

  ```text
  RELEASE\_PREFIXES was removed in v0.2.0; set ENABLE\_CI\_USER=true if it was non-empty, false if it was empty
  ```

  Replace a non-empty list with `ENABLE_CI_USER=true`; use
  `ENABLE_CI_USER=false` where the old list was empty.
- The `ReleasePrefixes` CloudFormation parameter is removed from **both** the
  operator and infra templates. `provision` no longer sends it; re-copy the
  canonical templates.

### `provision` refuses a true-to-false CI transition

- A `true`→`false` transition of `ENABLE_CI_USER` deletes the CI user and
  invalidates its access keys. `provision` **refuses** it before running the
  change set unless `--delete-ci-user` is passed; with the flag it proceeds and
  prints a **warning**. Capture or rotate any CI credentials you still need
  first.

### Re-vendoring

- Both `deploy/stackctl-operator.yaml` and `deploy/stackctl-infra.yaml` are
  copied **verbatim** from stackctl v0.2.0 with only the prepended line-1
  header
  `# Vendored from stackctl v0.2.0 -- re-copy on upgrade (see STACKCTL_MIGRATION.md).`
  Because the header is a single prepended line, `AWSTemplateFormatVersion:
  "2010-09-09"` is restored at line 2 of each file.
- Do not hand-edit policy content; re-copy on every pin move and re-run the
  two checker commands below.

## Runbook order (revised after the Phase 0 inventory)

The generic runbook (infra alongside, operator stack last) assumed a live
instance. The inventory found **no live strimserver instance** (the old
`deploy/aws/launch` tags instances with `Project=strimserver`, so the finding
is trustworthy), and the **old instance role is bucket-pinned**: its
`DeploymentBucketRead` policy only reads `arn:aws:s3:::strimserver.cvbn.cc/*`
(`deploy/aws/strimserver-operator.yaml:101`). A stackctl launch fetches the
bundle from the NEW hard-named bucket, so launching under the old profile
would fail with AccessDenied.

Therefore the operator stack is replaced **first**, not last. With nothing
live, no maintenance window is required.

## Project-specific mapping

| Old | New |
|---|---|
| Infra stack `strimserver` | Infra stack `strimserver-infra` |
| Operator stack `strimserver-operator` | Same name, replaced up front (Phase 1) — nothing live depends on it |
| Old artifact bucket (`strimserver.cvbn.cc`) | New hard-named `strimserver-artifacts-183438553939-us-east-2` |
| EC2 Image Builder pipeline | `ENABLE_IMAGE_BUILDER=true` + the BakedImage module |
| `deploy/aws/strimserver-{infra,operator}.yaml` | Vendored canonical `deploy/stackctl-*.yaml` |
| On-box `setup_strimserver` + `deploy.sh` | stackctl fetch/verify/extract + `stackctl-setup.sh` + `deploy.sh` |
| Twitch key scp'd by `setup_strimserver` | SSM SecureString `/strimserver/twitch-stream-key` read at boot |
| On-box `strim-ddns.{service,timer}` + verify unit | Retired; stackctl owns DDNS updates (`DDNS_ONBOX=false`) |
| Unversioned `releases/` history | Fresh `releases/<tag>/` history from the next tag |

Session Manager is **not carried over**: the old stack set
`EnableSessionManager=true`, but the canonical operator template attaches no
`AmazonSSMManagedInstanceCore`. SSH from `OPERATOR_CIDR` is the access path.
Ingress mapping (slots start at 0 because the SSH rule is separate):

- `INGRESS_TCP=4000:104.218.148.0/24,2222:104.218.148.0/24` -- controller and
  experimental OpenSSH, both operator-restricted.
- `INGRESS_UDP=9000:104.218.148.0/24` -- SRT ingest. **Settled (operator)**:
  scoped to the operator CIDR to match today's exposure exactly (the old stack
  had `IngestCidr=104.218.148.0/24`, not world-open). Widen only deliberately.
- Ordinary SSH (22) stays the template's conditional `SshIngress` from
  `OPERATOR_CIDR`.

Settled decisions (operator, 2026-11-15): UDP 9000 scoped as above; Session
Manager loss accepted (SSH from `OPERATOR_CIDR` is the access path); first
stackctl release tag is **`v1.0.80`** (next in the repo's existing `v1.0.x`
annotated-tag sequence, latest `v1.0.79`).

## Phase checklist

### Phase 0 -- Prepare (read-only)

- [x] Inventory recorded (`stackctl-phase0-inventory.sh` output, 2026-11-15):
      account 183438553939, region us-east-2, old stacks/IAM/bucket captured,
      no live instance, `/strimserver/twitch-stream-key` EXISTS,
      `/strimserver/ami/baked/latest` EXISTS.
- [ ] Create the MISSING DDNS SecureString (launch/status fail closed without
      it):

      aws ssm put-parameter \
        --name /strimserver/ddns/password \
        --type SecureString \
        --value "<the Namecheap DDNS password>"

- [ ] Ensure `~/.aws/credentials` has a **`[default]` admin profile** —
      `provision` authenticates as `[default]` (root/admin is fine) and itself
      mints + writes the `[strimserver]` profile key. The old user's secret is
      not needed; the old key dies with the old stack.
- [ ] Create `deploy/aws/.env` from `.env.example` with real values
      (`OPERATOR_CIDR=104.218.148.0/24`, `KEY_NAME`, `SSH_IDENTITY`,
      `DDNS_DOMAIN`, `IMAGE_BUILDER_PARENT_IMAGE=ami-0eb917ce8b21a5a71`,
      `INSTANCE_TYPES_AMD64=g4dn.xlarge`, `ROOT_VOLUME_SIZE=100`).
- [ ] Lower the DDNS record TTL in Namecheap (still worthwhile: the record may
      be resolving to a stale IP until first launch).
- [ ] Freeze new releases on the old pipeline.

### Phase 1 -- Operator-stack replacement (no window needed)

- [ ] Delete the old operator stack (nothing is live):

      aws cloudformation delete-stack --stack-name strimserver-operator
      aws cloudformation wait stack-delete-complete \
        --stack-name strimserver-operator

      This removes the old IAM user `strimserver` (and its access key), the
      old policies/role/profile, and the old ImageBuilder roles.

- [ ] Vendored templates are present and checker-clean:

      bazel run @stackctl//deploy/check:template_check -- \
        operator "$PWD/deploy/stackctl-operator.yaml"
      bazel run @stackctl//deploy/check:template_check -- \
        infra "$PWD/deploy/stackctl-infra.yaml"

- [ ] `bazel run //deploy/aws:stackctl -- provision` (runs as `[default]`)
      recreates the canonical operator stack — operator user + policy,
      instance role/profile with new-bucket read
      (`strimserver-artifacts-<acct>-*/releases/*`) and SSM secret read —
      and writes the fresh `[strimserver]` credentials profile.

### Phase 2 -- First release and new infra stack

- [ ] Push an annotated release tag (provenance gate requires it). First
      stackctl release: **`v1.0.80`**:

      git tag -a v1.0.80 -m "strimserver v1.0.80"
      git push origin v1.0.80

- [ ] Build the release targets so the freshness gate passes:

      bazel build //:strimserver_deployment_tar_go_amd64 \
        //:strimserver_deployment_tar_c_amd64 \
        //:strimserver_deployment_tar_go_arm64 \
        //:strimserver_deployment_tar_c_arm64

- [ ] `bazel run //deploy/aws:stackctl -- deploy` (now running as the
      `[strimserver]` profile) creates `strimserver-infra` + the new bucket
      and publishes `releases/<tag>/`.
- [ ] Copy legacy artifacts (ffmpeg/, openssh/, offline/, root tars) from the
      old bucket (read-only afterwards):

      aws s3 sync "s3://strimserver.cvbn.cc/" \
        "s3://strimserver-artifacts-183438553939-us-east-2/" --dry-run
      # then the same command without --dry-run

- [ ] Rendered security group verified: TCP 4000 + 2222 from
      `104.218.148.0/24`, UDP 9000 per the decision above, SSH 22 from
      `104.218.148.0/24`.

### Phase 3 -- Launch cutover

- [ ] `bazel run //deploy/aws:stackctl -- launch` succeeds; `stackctl-setup.sh`
      mounted the instance store, fetched the Twitch key from SSM, rendered
      `config/strimserver.env`, and `deploy.sh` exited 0.
- [ ] Instance carries the new project tags; DDNS points at the new IP; the
      dedicated stackctl known-hosts store is used.
- [ ] `stackctl terminate` is now the only teardown path.
- [ ] Raise the DDNS TTL back to normal.

### Phase 4 -- Decommission

- [ ] Delete the old `strimserver` infra stack after a full release cycle.
- [ ] Remove the old shell entry points and old per-project templates.
- [ ] Leave the old bucket read-only for one retention period, then delete it.
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

Keep `ENABLE_DDNS="false"` in `core/strimserver.env`. The old
`deploy.sh` still honors the flag, but the stackctl path never sets it to true.

## Vendored templates

`deploy/stackctl-operator.yaml` and `deploy/stackctl-infra.yaml` are copied
verbatim from stackctl v0.2.0 (plus the single prepended source-version header
comment). Re-copy both files whenever the `git_override` pin moves, then re-run
the two checker commands above.
