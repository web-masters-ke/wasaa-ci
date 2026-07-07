# wasaa-ci · Setup & Installation Guide

This guide walks you through **publishing wasaa-ci** (one-time, platform team) and **onboarding product repos** (per repo, product owners).

If you're onboarding an existing product repo, jump to [Part 2](#part-2--onboard-a-product-repo).

---

## The one-page summary

1. **Platform team, once**: push `wasaa-ci` to `github.com/web-masters-ke/wasaa-ci`, decide visibility, provision org secrets.
2. **Per product repo, ~10 minutes**: copy the matching template from `templates/` into `.github/workflows/ci.yml`, edit two lines (`stack:`, `db:`), commit, open a PR, watch the gate run.
3. **After first successful run on `main`**: enable branch protection so the gate becomes required.
4. **Ongoing**: read reports in the PR comment or the HTML dashboard artifact, fix findings locally or paste the "Share with Claude" block into Claude.

---

## Part 1 · Publish wasaa-ci (platform team, one-time)

### 1.1 · Prerequisites

- You are an admin of the `web-masters-ke` GitHub organization.
- You have `git` locally and are authenticated to GitHub (SSH key or `gh auth login`).
- You have this `wasaa-ci` directory at `/Users/mikemagero/WASAA2.0/wasaa-ci/` (or wherever it lives).

### 1.2 · Create the GitHub repo

```bash
# Option A: gh CLI (recommended)
gh repo create web-masters-ke/wasaa-ci \
  --description "Reusable GitHub Actions gate for Wasaa product repositories" \
  --public \
  --disable-issues=false \
  --disable-wiki

# Option B: create via web UI at https://github.com/organizations/web-masters-ke/repositories/new
#          name: wasaa-ci · visibility: Public · do not initialize with README
```

**Visibility choice:**

- **Public** (recommended) — simplest; no cross-repo permission fiddling. `wasaa-ci` contains no secrets, only rules and shell scripts. Being public also lets contributors on any Wasaa repo read the policy directly.
- **Private** — allowed, but adds friction. See § 1.6 for the extra config.

### 1.3 · Push the code

```bash
cd /Users/mikemagero/WASAA2.0/wasaa-ci
git init
git add -A
git commit -m "initial wasaa-ci gate policy"
git branch -M main
git remote add origin git@github.com:web-masters-ke/wasaa-ci.git
git push -u origin main
```

### 1.4 · Verify the repo

```bash
gh repo view web-masters-ke/wasaa-ci --web    # open in browser
```

You should see 63 files and a `POLICY.md` on the root.

### 1.5 · Provision org-level secrets

Go to `https://github.com/organizations/web-masters-ke/settings/secrets/actions` → **New organization secret** for each:

| Secret name                  | Value                  | Required? | Purpose                                              |
|------------------------------|------------------------|-----------|------------------------------------------------------|
| `WASAA_SEMGREP_APP_TOKEN`    | from Semgrep dashboard | Optional  | Higher-fidelity Semgrep rules + Cloud metrics       |
| `WASAA_TRIVY_TOKEN`          | from Aqua              | Optional  | Higher Trivy DB pull rate (avoids rate limits)      |
| `ANTHROPIC_API_KEY`          | from console.anthropic.com | **No — paused** | Only needed later when the autofix loop is un-paused |

For each secret's **Repository access**, choose "Selected repositories" or "All repositories in the organization" per your preference. Recommendation: **All repositories**, since the secrets are non-sensitive read tokens.

### 1.6 · If you chose "Private" in step 1.2

Two extra org settings must be flipped:

1. On `web-masters-ke/wasaa-ci` → **Settings → Actions → General → Access** → select **"Accessible from repositories in the 'web-masters-ke' organization."**
2. At the org level → **Settings → Actions → General** → under *"Policies"* enable **"Allow enterprise, organization, and repository actions and reusable workflows"** and **"Allow actions created by GitHub"**. Under *"Workflow permissions"* set the default so workflows can post PR comments (they need `contents: read` and `pull-requests: write`; the caller workflows declare these explicitly, so the default just needs to permit them).

### 1.7 · Smoke-test with a throwaway repo (optional but recommended)

```bash
gh repo create web-masters-ke/wasaa-ci-canary --private --clone
cd wasaa-ci-canary
cp ../wasaa-ci/templates/caller-node.yml .github/workflows/ci.yml
# add a trivial package.json + one .ts file with a deliberate issue
echo '{"name":"canary","version":"0.0.0"}' > package.json
mkdir src && echo 'const p = "hunter2"; console.log(p);' > src/index.ts
git add -A && git commit -m "canary" && git push -u origin main
gh pr create --title "test wasaa-ci" --body "smoke test"
```

Watch the PR — you should see `ci-fast` fail with findings from Gitleaks (hardcoded secret) and Semgrep (`no-console-log-in-prod`). If the gate runs at all, plumbing is working. Delete the canary repo after.

Done. Move to Part 2 for each product repo.

---

## Part 2 · Onboard a product repo

Per-repo. Takes 5–15 minutes depending on stack complexity. You need write access to the product repo.

### 2.1 · Identify your stack + services

Answer these before you copy any file:

- **Which languages are actually in the repo?** Combinations of `typescript`, `python`, `dart`, `go`. Not "we might add Rust later" — only what's present today.
- **Which databases does the repo interact with?** Any of `postgres`, `mongo`, `redis`, or `none`.
- **Does the repo publish an OpenAPI spec?** Look for `openapi.yaml`/`openapi.yml`/`openapi.json` anywhere in the tree.
- **Does the repo build a container image?** Look for a `Dockerfile` at the repo root (or wherever your build defines).
- **Does the repo have IaC?** Terraform, K8s manifests, Helm charts.
- **Does the repo produce a frontend bundle?** Next.js, Vite, Flutter Web — anything with a size-limit budget worth enforcing.

### 2.2 · Pick the right template

From `wasaa-ci/templates/`:

| Your repo has…                    | Use                       |
|-----------------------------------|---------------------------|
| Only TypeScript                   | `caller-node.yml`         |
| Only Python                       | `caller-python.yml`       |
| Only Dart / Flutter               | `caller-dart.yml`         |
| Only Go                           | `caller-go.yml`           |
| Multiple languages                | `caller-polyglot.yml`     |
| Anything + wants Claude autofix   | ⏸ PAUSED — use one of the above; autofix is not part of the current rollout |

### 2.3 · Drop it into the product repo

From inside the product repo:

```bash
mkdir -p .github/workflows
# example — TypeScript backend
curl -sSL -o .github/workflows/ci.yml \
  https://raw.githubusercontent.com/web-masters-ke/wasaa-ci/main/templates/caller-node.yml
```

Or if `wasaa-ci` is private, clone it and copy manually.

### 2.4 · Configure the caller

Open `.github/workflows/ci.yml` in the product repo. You'll see something like:

```yaml
jobs:
  fast:
    if: github.event_name == 'pull_request'
    uses: web-masters-ke/wasaa-ci/.github/workflows/ci-fast.yml@main
    with:
      stack: typescript          # <-- edit to match your reality
      db: postgres,redis         # <-- edit
      has_openapi: true          # <-- edit
      node_version: '20'
```

**Edit these inputs to match § 2.1:**

| Input                    | Type    | What to put                                                            |
|--------------------------|---------|------------------------------------------------------------------------|
| `stack`                  | string  | Comma-separated: `typescript`, `python`, `dart`, `go`                  |
| `db`                     | string  | Comma-separated: `postgres`, `mongo`, `redis`, or `none`               |
| `has_openapi`            | bool    | `true` if an OpenAPI spec is committed                                 |
| `has_frontend_bundle`    | bool    | `true` for Next/Vite/Flutter-web bundles                               |
| `has_container`          | bool    | `true` if there's a Dockerfile the CI should build+scan                |
| `has_iac`                | bool    | `true` for Terraform / K8s / Helm in the repo                          |
| `container_dockerfile`   | string  | Path to Dockerfile if not at repo root (`./Dockerfile`)                |
| `node_version` etc.      | string  | Language versions if different from defaults (20, 3.12, stable, 1.23) |

**Full inputs are documented at the top of each reusable workflow in `wasaa-ci/.github/workflows/*.yml`.**

### 2.5 · Repo-side prerequisites

The gate assumes a few conventions. Add them if missing:

**Every repo:**
- **`.dockerignore`** at the repo root, if `has_container: true`. Minimum entries: `.git`, `node_modules`, `.env*`, `coverage`, `dist`, `build`, `.venv`.
- **Lockfile committed**: `package-lock.json`/`pnpm-lock.yaml`/`yarn.lock` (TS), `poetry.lock`/`uv.lock`/`requirements.txt` (Py), `pubspec.lock` (Dart), `go.sum` (Go).

**TypeScript repos:**
- `tsconfig.json` with `"strict": true`.
- A test runner installed (`jest` or `vitest`).

**Python repos:**
- `pyproject.toml` OR `requirements.txt` — one of them so the setup step knows how to install.
- `pytest` installed as a dev dep.

**Dart/Flutter repos:**
- Fine as-is. The gate copies its own `analysis_options.yaml` alongside yours.

**Go repos:**
- `go.mod` tidy (`go mod tidy` produces no diff).

**All repos with a Dockerfile:**
- Non-root `USER` declared.
- `HEALTHCHECK` declared.
- No `FROM ...:latest`.
- Multi-stage OR use `-slim` / `-alpine` / `distroless` base.
- See `POLICY.md § Coverage · Container hygiene` for the full list.

### 2.6 · First run — expect failures

Open a small PR (e.g. add a comment to a README):

```bash
git checkout -b onboard-wasaa-ci
git commit --allow-empty -m "trigger wasaa-ci"
git push -u origin onboard-wasaa-ci
gh pr create --title "onboard wasaa-ci" --body "First gate run"
```

Watch the PR. What to expect on first-ever run for an established codebase:

- **`ci-fast` will almost certainly fail.** Pre-existing findings across Semgrep, ESLint, Bandit, gosec, etc. are normal.
- **A sticky PR comment** titled `wasaa-ci-report` appears with the verdict + top 15 findings.
- **A `wasaa-ci-report-fast` artifact** appears on the run page — download it and open `index.html` for the full filterable dashboard.
- **Inline SARIF annotations** appear on affected lines in the PR diff view.

### 2.7 · Burn down or waive findings

For each blocking finding, use the loop in `README.md § Manual triage`:

1. **Fix it locally** — see `README.md § Reproduce a finding locally` for exact commands.
2. Or **file a waiver** if it's genuinely architectural and can't be fixed this cycle. Create `.wasaa-ci-waiver.yml` at the repo root:

   ```yaml
   - rule_id: "semgrep.wasaa-no-md5-sha1"
     path: "src/legacy/checksum.ts"
     reason: "Non-security hash — file dedupe only. Migration to xxhash tracked in TICKET-1234."
     expires: "2026-08-15"
     approved_by: "@security-lead-handle"
   ```

   Waivers are max 30 days, bound to a `rule_id` + `path`, and must be approved by a Security lead.

3. Or, if a rule is producing false positives across many repos, open a PR against `web-masters-ke/wasaa-ci` to tune the rule at the source.

### 2.8 · When the fast gate passes, enable branch protection

Only after your PR turns green:

Go to `<product-repo>` → **Settings → Branches → Add branch protection rule**:

- **Branch name pattern**: `main`
- Check **"Require a pull request before merging"**.
- Check **"Require status checks to pass before merging"** → search and select `ci-fast / summary` (and `report` if you also want the report to be enforced).
- Optional: **"Require branches to be up to date before merging"**.
- Optional but recommended: **"Do not allow bypassing the above settings"**.

Save.

For deploy-tag branches (`v*.*.*`), the gate enforces itself: the caller template's `deploy:` job declares `needs: full`, so a failing `ci-full-gate` prevents deploy automatically.

### 2.9 · Optional — enable auto-runs on `main` push

The template already runs `ci-full-gate` on push-to-main and on tag creation. Nothing else to configure. The first push after merging your onboarding PR will trigger a `ci-full-gate` run — that's your baseline for release readiness.

---

## Part 3 · Verify end-to-end

After branch protection is on:

- [ ] Open a PR with a deliberate bad change (e.g. `const secret = "sk-live-abc123"`). Confirm the gate blocks the merge.
- [ ] Undo the bad change, push again. Confirm the gate goes green and merge is unblocked.
- [ ] Merge to `main`. Confirm `ci-full-gate` runs.
- [ ] Cut a tag (`git tag v0.0.1 && git push --tags`). Confirm `ci-full-gate` runs on the tag AND the deploy job blocks if it fails.

---

## Part 4 · Ongoing operation

### 4.1 · Reading a failing PR

Three views, from quickest to fullest:

1. **PR sticky comment** — verdict, severity counts, top 15 blocking findings, plus a copy-pasteable "Share with Claude" block.
2. **Inline annotations** in the PR diff — click "Files changed" and scroll; SARIF findings appear on the exact lines.
3. **HTML dashboard** — go to the Actions run → Artifacts → download `wasaa-ci-report-<gate>` → open `index.html` in a browser. Filter by severity/tool/file.

### 4.2 · Sharing findings with Claude

Copy the "📋 Share with Claude" fenced block from the PR comment. Paste it into Claude Code (inside the failing repo's working directory) or into claude.ai. It contains the finding list plus the policy ground rules so Claude doesn't propose suppressions or type-widening.

Or, locally, from a downloaded artifact:

```bash
scripts/share-with-claude.sh ./wasaa-ci-report-fast/ | pbcopy   # macOS
scripts/share-with-claude.sh ./wasaa-ci-report-fast/ | claude   # pipe to Claude Code
```

### 4.3 · Reproducing a finding locally

Every tool the gate runs is invokable locally against the shared configs:

```bash
# Assumes wasaa-ci is checked out as a sibling directory
docker run --rm -v "$(pwd):/src" -v "$(pwd)/../wasaa-ci/configs/semgrep:/rules" \
  semgrep/semgrep semgrep --config /rules --error --severity ERROR /src

npx eslint --config ../wasaa-ci/configs/eslint/.eslintrc.wasaa.json --ext .ts,.tsx .

ruff check --config ../wasaa-ci/configs/ruff.toml .
bandit -c ../wasaa-ci/configs/bandit.yaml -r .

gofmt -l . && go vet ./... && staticcheck ./... && govulncheck ./...
golangci-lint run --config ../wasaa-ci/configs/golangci.yml

dart analyze --fatal-infos --fatal-warnings

bash ../wasaa-ci/scripts/nplus1-detect.sh
bash ../wasaa-ci/scripts/mongo-query-audit.sh
bash ../wasaa-ci/scripts/redis-usage-audit.sh
bash ../wasaa-ci/scripts/docker-optimization-audit.sh
bash ../wasaa-ci/scripts/docker-compose-audit.sh
```

### 4.4 · Filing a waiver

Waivers live at the **product repo root** as `.wasaa-ci-waiver.yml`. See `wasaa-ci/templates/wasaa-ci-waiver.example.yml` for the exact schema. Rules:

- Bound to `rule_id` + `path`.
- Time-boxed. Max 30 days. No renewals — reopen a fresh waiver with fresh justification.
- Requires Security-lead PR approval.
- Reviewed weekly. Expired waivers auto-revert the finding to blocking.

### 4.5 · Requesting a rule change

If a rule is misconfigured or too noisy:

1. Open an issue on `web-masters-ke/wasaa-ci` with: rule ID, links to false-positive examples across 2+ repos, proposed fix.
2. Discuss with the platform team.
3. If agreed, open a PR against `wasaa-ci` modifying the rule.
4. New rules land in **advisory mode** (WARNING severity, not blocking) for one release cycle before promotion to ERROR.

---

## Part 5 · Troubleshooting

### Symptom: workflow fails with `could not find reusable workflow file`

**Cause**: `wasaa-ci` is private and the product repo doesn't have access, OR the workflow reference uses the wrong org/repo name.

**Fix**: See § 1.6. Confirm the exact `uses:` line matches `web-masters-ke/wasaa-ci/.github/workflows/<name>.yml@main`.

### Symptom: `ci-fast` succeeds but no PR comment appears

**Cause**: workflow needs `pull-requests: write` permission. The reusable workflows declare it, but if your product repo caller adds `permissions:` overrides, it can suppress this.

**Fix**: remove any `permissions:` block from your caller `ci.yml`, OR explicitly include `pull-requests: write`.

### Symptom: `docker build` inside `security-container.yml` fails with "no such file: Dockerfile"

**Cause**: `has_container: true` but the Dockerfile is not at the repo root.

**Fix**: set `container_dockerfile: path/to/Dockerfile` in your caller.

### Symptom: `pip-audit` or `npm audit` fails on transitive vulns you can't upgrade past

**Cause**: an indirect dep has an unfixed CVE.

**Fix**: file a waiver documenting why (usually: "no fix available upstream, vulnerable code path not reachable — verified with strace/grep").

### Symptom: `squawk` fails on an existing migration

**Cause**: an old migration violates a new policy (e.g. `ADD COLUMN NOT NULL` without default).

**Fix**: squawk lints only changed migrations on PRs (fast mode). Existing migrations that pre-date the policy shouldn't trigger. If they do, waive with an explanation — do NOT retroactively edit committed migrations.

### Symptom: coverage fails at 68% and you can't hit 70% before deadline

**Cause**: threshold is `coverage_overall_min: 70` by default.

**Fix (not recommended)**: adjust the input in your caller for a short-term reprieve:
```yaml
with:
  coverage_overall_min: 65
```
Only do this with a Slack message to the platform team explaining why and a follow-up ticket to burn down.

### Symptom: image is 800 MB and `dive` fails at the 500 MB soft warning

**Cause**: single-stage build using a full-fat base image.

**Fix**: convert to multi-stage; final stage uses `-slim`, `-alpine`, or `distroless`. Follow `scripts/docker-optimization-audit.sh` output — it names each violation.

### Symptom: gate runs forever / times out

**Cause**: usually a `pnpm install` or `flutter pub get` fetching everything with no cache.

**Fix**: ensure your lockfile is committed. The workflows use `cache: true` on setup actions, but need a lockfile to key the cache.

### Where to get help

- **Platform channel** (Slack `#eng-platform` or equivalent) — plumbing questions.
- **Security channel** (`#security`) — waiver approvals, policy questions.
- **This repo's issues** — bugs, rule tuning, new-language requests.

---

## Appendix · Reference

### File map

| File                                  | Purpose                                              | Owner              |
|---------------------------------------|------------------------------------------------------|--------------------|
| `POLICY.md`                           | The enforced contract                                | Security + Eng leads |
| `README.md`                           | Consumer-facing overview                             | Platform           |
| `SETUP.md`                            | This guide                                           | Platform           |
| `.github/workflows/ci-fast.yml`       | PR-time orchestrator                                 | Platform           |
| `.github/workflows/ci-full-gate.yml`  | Release-time orchestrator                            | Platform           |
| `.github/workflows/lang-*.yml`        | Per-language quality checks                          | Platform           |
| `.github/workflows/security-*.yml`    | Security scans                                       | Platform + Security |
| `.github/workflows/db-safety.yml`     | Migration + N+1 checks                               | Platform           |
| `.github/workflows/quality-*.yml`     | Tests, coverage, API contract, perf                  | Platform           |
| `.github/workflows/report-aggregate.yml` | Roll-up report                                    | Platform           |
| `configs/`                            | Shared tool configs                                  | Platform + Security |
| `configs/license-allowlist.json`      | OSS licenses accepted org-wide                       | Legal + Security   |
| `scripts/`                            | Custom heuristics + helpers                          | Platform           |
| `templates/`                          | Drop-in caller workflows                             | Platform           |
| `.claude/instructions/autofix.md`     | Claude autofix playbook (paused)                     | Platform           |

### Command cheat sheet

```bash
# Onboard a repo (from the product repo root)
mkdir -p .github/workflows && \
  curl -sSL -o .github/workflows/ci.yml \
  https://raw.githubusercontent.com/web-masters-ke/wasaa-ci/main/templates/caller-node.yml

# Reproduce a finding locally (from the product repo root, wasaa-ci as sibling)
bash ../wasaa-ci/scripts/nplus1-detect.sh
bash ../wasaa-ci/scripts/docker-optimization-audit.sh
bash ../wasaa-ci/scripts/docker-compose-audit.sh

# Share the last CI run's findings with Claude
bash ../wasaa-ci/scripts/share-with-claude.sh ./wasaa-ci-report-fast/ | pbcopy

# Update your consumption to a new wasaa-ci release
# Change all `@main` refs in .github/workflows/ci.yml to a pinned SHA or tag
```

### Support matrix

| Language / DB / Container feature | Supported | Notes                                              |
|-----------------------------------|-----------|----------------------------------------------------|
| TypeScript (Node 18/20/22)        | ✅        | ESLint + tsc strict + jest/vitest                 |
| Python (3.10 / 3.11 / 3.12)       | ✅        | ruff, mypy, bandit, pytest                        |
| Dart / Flutter (stable)           | ✅        | dart analyze, dart_code_metrics                   |
| Go (1.22 / 1.23)                  | ✅        | golangci-lint, staticcheck, gosec, govulncheck    |
| Rust / Java / Ruby                | ❌ not yet | Open an issue if needed                           |
| PostgreSQL                        | ✅        | sqlfluff + squawk + custom index audit             |
| MongoDB                           | ✅        | custom query pattern audit                        |
| Redis                             | ✅        | custom usage audit                                 |
| MySQL / MariaDB                   | ⚠️ partial | sqlfluff supports; no dedicated migration linter yet |
| DynamoDB / Cassandra              | ❌ not yet | Open an issue                                     |
| Docker                            | ✅        | Trivy image + hadolint + dockle + dive + custom  |
| Docker Compose                    | ✅        | custom hygiene audit                              |
| Kubernetes / Helm                 | ✅        | Checkov + kube-linter                             |
| Terraform                         | ✅        | Checkov                                            |
