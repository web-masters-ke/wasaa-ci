# wasaa-ci

Reusable GitHub Actions workflows that enforce Wasaa's engineering, security, and DevSecOps gate on every product repository.

**Read [POLICY.md](./POLICY.md) first — that's the contract.**
**Setting up a repo? See [SETUP.md](./SETUP.md) — step-by-step guide.**

## What this is

A single central repo (`web-masters-ke/wasaa-ci`) that exports reusable workflows. Each product repo has a small caller workflow (~30 lines) that invokes them. When a rule or threshold changes, we update this repo once and every product picks it up on their next PR.

## Two gates

| Gate            | When                                | Purpose                          |
|-----------------|-------------------------------------|----------------------------------|
| `ci-fast`       | Every PR                            | Fast, cheap deterministic checks |
| `ci-full-gate`  | Push to `main` and every `v*.*.*` tag | Full DevSecOps sweep before deploy |

**No repo deploys without passing `ci-full-gate`.** Deploy workflows must declare `needs: ci-full-gate`.

## Quick start (product repo)

1. Copy the template that matches your stack from [`templates/`](./templates) into `.github/workflows/ci.yml`:

   - `caller-node.yml` — TypeScript / Node
   - `caller-python.yml` — Python
   - `caller-dart.yml` — Dart / Flutter
   - `caller-go.yml` — Go
   - `caller-polyglot.yml` — repos with multiple languages
   - `caller-with-autofix.yml` — **PAUSED**. Do not use for the current rollout. See § Deferred: Claude autofix loop.

2. Set the `stack` and `db` inputs to match what your repo actually uses. Everything else has sensible defaults.

3. Ensure these org-level secrets exist (Security has provisioned them):
   - `WASAA_TRIVY_TOKEN` — optional, for higher Trivy DB pull-rate.
   - `WASAA_SNYK_TOKEN` — optional, only if repo opts into Snyk in addition to Trivy.
   - `WASAA_SEMGREP_APP_TOKEN` — optional, for Semgrep Cloud metrics.
   - `GITHUB_TOKEN` — provided by GitHub, used for CodeQL, SBOM upload, PR annotations.
   - `ANTHROPIC_API_KEY` — **not needed for the current rollout** (autofix is paused). Only required if/when the Claude autofix loop is re-enabled.

4. Add a branch protection rule on `main`:
   - Require `ci-fast / summary` to pass on PRs.
   - Require `ci-full-gate / summary` to pass before deploy.

## Directory layout

```
.github/workflows/          reusable workflows called by product repos
  ci-fast.yml               orchestrator: PR-time fast gate
  ci-full-gate.yml          orchestrator: full DevSecOps gate for release
  lang-typescript.yml       TS lint / type / format / complexity / dead code
  lang-python.yml           Python lint / type / format / complexity
  lang-dart.yml             Dart / Flutter analyze / format
  lang-go.yml               Go fmt / vet / staticcheck / golangci-lint / race+cover
  security-sast.yml         Semgrep + CodeQL (TS, Python, Go)
  security-secrets.yml      Gitleaks + TruffleHog
  security-sca.yml          Trivy fs + npm/pip/pub audit + govulncheck + gosec + nancy
  security-container.yml    Trivy image + hadolint + dockle + dive + Dockerfile-opt + compose-hygiene + Checkov + kube-linter
  security-sbom.yml         Syft SBOM + license allowlist (TS/Py/Dart/Go)
  db-safety.yml             sqlfluff, squawk, mongo/redis lint, N+1 heuristics
  quality-tests.yml         tests + coverage gate
  quality-api.yml           Spectral + openapi-diff
  quality-perf.yml          size-limit / Lighthouse CI / pytest-benchmark
  report-aggregate.yml      merges all SARIF/JSON into HTML + Markdown report
  claude-autofix.yml        Claude sub-agent that fixes findings on failing PRs

.claude/
  instructions/
    autofix.md              standing instructions loaded by the autofix agent

configs/                    tool configs (checked out by workflows)
  semgrep/                  custom rulesets per language
  eslint/                   security ESLint config
  spectral/                 wasaa OpenAPI ruleset
  sqlfluff/                 SQL style config
  gitleaks.toml             gitleaks rules
  trivy.yaml                trivy config
  hadolint.yaml             hadolint rules
  checkov.yaml              checkov config
  license-allowlist.json    approved OSS licenses

scripts/                    custom heuristics
  nplus1-detect.sh          ORM N+1 heuristic (TS, Python, Dart, Go)
  mongo-query-audit.sh      unsafe Mongo pattern audit
  redis-usage-audit.sh      Redis pattern audit
  db-index-audit.sh         Postgres missing-index heuristic
  docker-optimization-audit.sh  Dockerfile best-practices + image-size discipline
  docker-compose-audit.sh   docker-compose production hygiene lint
  gate-summary.sh           roll-up + PR comment
  build_report.py           aggregates SARIF + JSON into HTML/MD/JSON reports
  severity-gate.sh          hard pass/fail decision
  share-with-claude.sh      extracts Claude-ready prompt block from a report

templates/                  drop-in caller workflows for product repos
```

## Design principles

- **Deterministic only in the gate.** No LLM in the blocking path. Reproducible, cheap, auditable.
- **Configs live here, not in product repos.** Product repos should not need a `.semgrepignore` or a custom ESLint rule to pass the gate. If they do, that's a signal to update the shared ruleset (or file a waiver).
- **Fail closed.** Any tool that errors out (network flake, missing binary) fails the gate. Retry is fine; silent-skip is not.
- **Findings render as PR annotations.** Every workflow uploads SARIF where possible so findings appear inline in the diff.

## Adding a new rule

1. Add the rule to the appropriate config in `configs/`.
2. Ship it in **advisory mode** first — a warning that does not block. See `severity-gate.sh --advisory <rule_id>`.
3. Give product repos one release cycle to catch up.
4. Promote to blocking by removing it from the advisory list in `POLICY.md`.

## Local reproduction

Every reusable workflow's job body must be runnable locally with the same config. Where possible we invoke tools directly (not GitHub-specific actions) so `act` and dev containers reproduce CI 1:1.

```bash
# example: run Semgrep the same way CI does
docker run --rm -v "$(pwd):/src" -v "$(pwd)/wasaa-ci/configs/semgrep:/rules" \
  semgrep/semgrep semgrep --config /rules --error --severity ERROR /src
```

## Reports

Every run produces a downloadable **`wasaa-ci-report-<gate>`** artifact containing:

- `index.html` — a single-file dashboard with filter/sort by severity, tool, file. Open it in a browser.
- `report.md` — the PR comment (sticky, updated per run).
- `findings.json` — normalized machine-readable findings (consumed by the autofix agent).
- `findings.sarif` — merged SARIF, ingestible into GH code scanning or any SARIF viewer.

Findings also render **inline in the PR diff** for every SARIF-emitting tool (Semgrep, ESLint, Bandit, gosec, golangci-lint, Trivy, Checkov, hadolint, Gitleaks, kube-linter). Reviewers see them on the exact lines that produced them.

## Manual triage (current rollout)

Autofix is paused. Developers triage findings manually. The gate still runs on every PR and every release-tag build; only the "who applies the fix" step is human.

### The loop

1. Push a PR.
2. `ci-fast` runs. Findings surface in three places:
   - **Inline in the PR diff** — every SARIF-emitting tool (Semgrep, ESLint, Bandit, gosec, golangci-lint, Trivy, Checkov, hadolint, Gitleaks, kube-linter) annotates the exact lines.
   - **Sticky PR comment** posted by `wasaa-ci-report` — verdict, severity counts, top 15 blocking findings.
   - **`wasaa-ci-report-fast` artifact** on the Actions run page — download and open `index.html` in a browser for a filterable dashboard of every finding.
3. Fix locally. See § Reproduce a finding locally.
4. Push again. `ci-fast` re-runs. Repeat until green.
5. Merge to `main`. `ci-full-gate` runs. If it passes, tag `v*.*.*` to trigger deploy (deploys hard-depend on `ci-full-gate`).

### What to fix first

Order dictated by [POLICY.md § Severity model](./POLICY.md#severity-model):

1. **CRITICAL** — always fix. Blocks even the fast gate. Includes any secret in git, RCE-class SAST hits, missing auth, `eval`/`pickle.loads(untrusted)`/`fmt.Sprintf` SQL.
2. **HIGH** — fix on the same PR. Blocks `ci-full-gate` and therefore blocks deploy.
3. **MEDIUM** — track and schedule. Warns, doesn't block. Don't let these accumulate.
4. **LOW / NOTE** — report-only. Ignore unless clustered.

### Where NOT to apply the fix

Same guardrails apply as the autofix agent would have followed. Do not:

- Add `// eslint-disable`, `# noqa`, `# type: ignore`, `# nosec`, `//nolint`, or `nosemgrep:` comments to suppress a finding. Use a time-boxed waiver (`.wasaa-ci-waiver.yml`) if suppression is justified.
- Widen types to `any` / `interface{}` / `dynamic` to make a type error go away.
- Delete tests or lower coverage thresholds.
- Remove `NOT NULL` / `UNIQUE` / FK constraints in migrations to bypass squawk.
- Edit anything in `.github/workflows/` or `.wasaa-ci/**` in a product repo.

### Reproduce a finding locally

Every reusable workflow calls its tool directly (not a GH-specific action wrapper) so you can reproduce the exact check locally against the same config.

```bash
# Semgrep — same rules the gate uses
docker run --rm -v "$(pwd):/src" -v "$(pwd)/../wasaa-ci/configs/semgrep:/rules" \
  semgrep/semgrep semgrep --config /rules --error --severity ERROR /src

# ESLint (TS/JS)
npx eslint --config ../wasaa-ci/configs/eslint/.eslintrc.wasaa.json --ext .ts,.tsx,.js,.jsx .

# Ruff + Bandit (Python)
ruff check --config ../wasaa-ci/configs/ruff.toml .
bandit -c ../wasaa-ci/configs/bandit.yaml -r .

# Go
gofmt -l . && go vet ./... && staticcheck ./... && \
  golangci-lint run --config ../wasaa-ci/configs/golangci.yml && \
  govulncheck ./...

# Dart / Flutter
dart analyze --fatal-infos --fatal-warnings

# Custom heuristics (any stack)
bash ../wasaa-ci/scripts/nplus1-detect.sh
bash ../wasaa-ci/scripts/mongo-query-audit.sh
bash ../wasaa-ci/scripts/redis-usage-audit.sh
```

If a finding is a genuine false positive, do **not** suppress it. Post a comment on the PR explaining why, and either the rule gets tuned upstream (in this repo) or a scoped waiver gets approved by Security. See [POLICY.md § Waiver process](./POLICY.md#waiver-process).

### Share findings with Claude

Every failing run's PR comment ends with a **📋 Share with Claude** block containing a self-contained prompt: the repo + SHA, gate verdict, severity counts, the policy ground-rules (no suppressions, no type-widening, etc.), and the top 40 blocking findings with `severity | tool/rule | file:line | message`. Copy the fenced block straight into Claude Code (inside the failing repo's working dir) or claude.ai to get a targeted fix plan.

For the complete finding set (beyond 40), download the `wasaa-ci-report-<gate>` artifact and attach `findings.json` to the conversation.

Local shortcut — extract the same block from a downloaded artifact without opening the browser:

```bash
# From a report directory or the artifact zip
scripts/share-with-claude.sh ./wasaa-ci-report-fast/            # dir
scripts/share-with-claude.sh wasaa-ci-report-full.zip           # zip

# Straight to clipboard (macOS) or Claude Code stdin
scripts/share-with-claude.sh ./wasaa-ci-report-fast/ | pbcopy
scripts/share-with-claude.sh ./wasaa-ci-report-fast/ | claude
```

### When you're stuck

- Ask on the platform channel with the run link + the finding's `rule_id`.
- If the finding is architecturally unfixable this cycle, file a waiver (max 30 days, requires Security-lead approval).
- If a rule is producing repeated false positives across repos, open a PR against `web-masters-ke/wasaa-ci` to fix the rule at the source.

## Deferred: Claude autofix loop

Paused as of 2026-07-07. The scaffolding is kept intact so it can be turned back on without a rebuild:

- Workflow: `.github/workflows/claude-autofix.yml` (marked `STATUS: PAUSED` at the top)
- Playbook: `.claude/instructions/autofix.md`
- Caller template: `templates/caller-with-autofix.yml` (marked `STATUS: PAUSED`)

To resume: unpause the caller template's usage in product repos and provision `ANTHROPIC_API_KEY` as an org secret. Bounded at 3 iterations per PR, sandboxed to code files only, guarded against editing CI/policy files.

## Waivers

See [POLICY.md § Waiver process](./POLICY.md#waiver-process). Waivers live in the product repo at `.wasaa-ci-waiver.yml` and are consumed by `scripts/gate-summary.sh`.

## Ownership

| Concern                | Owner                     |
|------------------------|---------------------------|
| Policy thresholds      | Security + Engineering leads |
| Tool configs           | Platform team             |
| Custom scripts         | Platform team             |
| Waiver approvals       | Security lead             |
| Incident response      | On-call + Security        |
