# Wasaa CI Gate Policy

This is the **contract**. Every repository in the Wasaa ecosystem must pass this gate before code reaches production. Nothing in this policy is optional — exceptions require an explicit `.wasaa-ci-waiver.yml` approved by the Security lead and expire after 30 days.

## The two gates

| Gate            | Trigger                                          | Purpose                                                      | Blocks                          |
|-----------------|--------------------------------------------------|--------------------------------------------------------------|---------------------------------|
| **ci-fast**     | Every PR opened / synchronized                   | Fast feedback for the author. Runs cheap deterministic checks. | Merge to `main`                 |
| **ci-full-gate**| Push to `main`, and every tag matching `v*.*.*`  | Full DevSecOps sweep. What actually protects production.     | Deploy (release job depends on it) |

A deploy workflow **must** declare `needs: ci-full-gate` on its release job. Deploys that skip the gate are a security incident.

## Severity model

Every finding maps to one of four severities:

| Severity  | Meaning                                                                                              | Behavior     |
|-----------|------------------------------------------------------------------------------------------------------|--------------|
| CRITICAL  | Direct exploit path, active leak, RCE, auth bypass, secret in git history, CVSS >= 9.0.              | Block always. |
| HIGH      | Likely exploit under realistic assumptions, CVSS 7.0–8.9, missing auth on sensitive endpoint, PII leak in logs. | Block on full gate. Warn on fast gate. |
| MEDIUM    | Weakness that requires chained conditions to exploit, CVSS 4.0–6.9.                                  | Warn. Tracked in dashboard. |
| LOW       | Best-practice deviation, style, minor perf.                                                          | Report only. |

**A single CRITICAL or HIGH in the full gate fails the build. No exceptions without waiver.**

## Coverage requirements

| Concern                    | Tool(s)                                                            | Threshold                                                      |
|----------------------------|--------------------------------------------------------------------|----------------------------------------------------------------|
| SAST (multi-language)      | Semgrep (custom + p/ci p/security-audit p/secrets), CodeQL         | 0 CRITICAL, 0 HIGH                                             |
| SAST — TS                  | ESLint (security, no-secrets, sonarjs), tsc `--strict`             | 0 errors                                                       |
| SAST — Python              | Bandit, ruff (S, B, PLE), mypy `--strict` on new files             | 0 CRITICAL/HIGH bandit; 0 ruff errors                          |
| SAST — Dart/Flutter        | `dart analyze --fatal-infos`, `flutter analyze`, dart_code_metrics | 0 issues                                                       |
| SAST — Go                  | gosec, staticcheck, golangci-lint (errcheck, gosec, revive, gocyclo, gocritic, bodyclose, sqlclosecheck, rowserrcheck, noctx, contextcheck, errorlint) | 0 errors. `go vet ./...` clean. gofmt/goimports clean. |
| Secrets scanning           | Gitleaks (repo + full history on release), TruffleHog verified     | 0 verified findings                                            |
| Dependency SCA             | Trivy fs, npm audit `--audit-level=high`, pip-audit, `flutter pub outdated`, govulncheck | 0 CRITICAL, 0 HIGH (transitive included). Lockfiles must be committed. `go.mod`/`go.sum` must be tidy. |
| Container CVE              | Trivy image (final image), hadolint on Dockerfile                  | 0 CRITICAL, 0 HIGH unfixed. `USER` must not be root. `HEALTHCHECK` required. |
| Container hygiene          | dockle (CIS Docker Benchmark + image best-practices), custom Dockerfile audit | 0 warn/fatal. Multi-stage OR minimal base (`-slim`/`-alpine`/`distroless`/scratch). No `ADD` for local files. `apt-get` must use `--no-install-recommends` + cache cleanup in same RUN. CMD/ENTRYPOINT in exec form. No secret-shaped ARG/ENV. `WORKDIR` set. `.dockerignore` required. |
| Image size + layers        | dive layer efficiency + size budget                                 | Efficiency >= 95%, single-layer waste <= 10 MB, image <= 500 MB warn / 1024 MB hard block. |
| Docker Compose hygiene     | `docker compose config` + custom compose audit                       | 0 CRITICAL/HIGH: no `:latest` / unpinned images, no `privileged: true`, no `pid/ipc/network_mode: host`, no inline secret env, no `/`, `/etc`, `/var` or `docker.sock` bind-mount, restart policy set, memory + CPU limits set, no root user, no unnecessary `0.0.0.0` port bindings. |
| IaC misconfig              | Checkov (Terraform, K8s, Dockerfile, Helm), kube-linter            | 0 CRITICAL, 0 HIGH                                             |
| SBOM                       | Syft (CycloneDX + SPDX)                                            | Must be generated and attached to release. Not gated.          |
| License compliance         | `license-checker` (npm), `pip-licenses`, `dart pub deps`           | Allowlist only (see `configs/license-allowlist.json`)          |
| DB migration safety (PG)   | squawk                                                             | 0 errors. `ADD COLUMN NOT NULL` without default = blocked. Non-`CONCURRENTLY` indexes on tables >1M rows = blocked. |
| DB migration safety (Mongo)| Custom lint (see `scripts/mongo-migration-lint.sh`)                | Full-collection `updateMany` without index hint = blocked.     |
| SQL style                  | sqlfluff (postgres dialect)                                        | 0 errors                                                       |
| N+1 detection              | Custom heuristics per ORM (Prisma, TypeORM, SQLAlchemy, Django, Drift, GORM, sqlx, database/sql) | 0 findings in `for/forEach/map/range` loops calling ORM methods |
| Redis usage audit          | Custom lint (see `scripts/redis-usage-audit.sh`)                   | Bans `KEYS *`, unbounded `LRANGE 0 -1`, missing TTL on cache keys |
| Code quality               | Language-native lint + format + complexity (radon, complexity-report, dart_code_metrics) | Cyclomatic complexity < 15 on new code, file length < 500 lines |
| Test coverage              | Language-native (jest/vitest, pytest, `flutter test --coverage`, `go test -race -cover`) | Line coverage >= 70% overall, >= 80% on files changed in the PR. Race detector required for Go. |
| API contract               | Spectral (with wasaa custom ruleset), openapi-diff                 | 0 errors. Breaking change to a versioned public API = blocked. |
| Performance budget         | size-limit (frontend bundles), pytest-benchmark (backend hot paths) | Bundle regression > 10% blocked. Benchmark regression > 20% blocked. |

## Immutable baselines

Some rules cannot be waived, ever, regardless of severity heuristics:

1. **No secrets in git history.** Rotating and force-pushing is required, not optional.
2. **No `eval` / `Function()` / `pickle.loads(untrusted)` / `dart:mirrors` runtime injection** in production code paths.
3. **No SQL/NoSQL string concatenation** on user input — must use parameterized queries or a validated ORM.
4. **No secrets in CI logs.** Mask via `::add-mask::` or fail the job.
5. **No `latest` tag** on production container images or in docker-compose `image:` fields. Immutable digest or semver tag only.
6. **No image built without a non-root `USER`.**
7. **No docker-compose service with `privileged: true`, `network_mode: host`, `pid: host`, `ipc: host`, or a `/var/run/docker.sock` bind-mount** (outside explicit orchestration services).
8. **No inline secret-shaped values in docker-compose `environment:`** (API_KEY, SECRET, PASSWORD, TOKEN). Must use `${VAR}` substitution from `.env`/secrets store or a Compose `secrets:` block.
7. **No PR merged with a failing full gate on `main`.** If `main` is red, all merges pause until green.

## Waiver process

A finding may be waived by adding a `.wasaa-ci-waiver.yml` entry:

```yaml
- rule_id: "semgrep.security.audit.sqli.node-postgres-sqli"
  path: "src/legacy/report-generator.ts"
  reason: "Legacy admin-only report tool. Access is restricted to internal VPN. Migration to parameterized queries tracked in TICKET-4821."
  expires: "2026-08-01"
  approved_by: "@security-lead-github-handle"
```

Waivers are:
- Bound to a specific `rule_id` and `path`.
- Time-boxed. Max 30 days. No renewals — reopen a fresh waiver with a new justification.
- Reviewed weekly by Security. An expired waiver reverts the finding to blocking.

## Reporting

Every gate run produces four artifacts, downloadable from the GitHub Actions run page:

| Artifact                     | Format          | Purpose                                                     |
|------------------------------|-----------------|-------------------------------------------------------------|
| `wasaa-ci-report-<gate>/index.html`  | HTML (single file) | Human dashboard: filter/sort every finding by severity, tool, file. |
| `wasaa-ci-report-<gate>/report.md`   | Markdown           | Sticky PR comment. Verdict + top 15 blocking findings.       |
| `wasaa-ci-report-<gate>/findings.json` | JSON               | Machine-readable. Consumed by the autofix agent.             |
| `wasaa-ci-report-<gate>/findings.sarif` | SARIF 2.1.0        | Merged from all tools. Ingestible into GH code scanning, Sonar, etc. |

SARIF results also render **inline in the PR diff** for every SARIF-emitting tool (Semgrep, ESLint, Bandit, gosec, golangci-lint, Trivy, Checkov, hadolint, Gitleaks, kube-linter). Reviewers see findings on the exact lines that produced them.

## Triage process

**Current rollout: manual triage.** The gate runs automatically on every PR and release build. Fixes are applied by humans. See [README § Manual triage](./README.md#manual-triage-current-rollout) for the loop.

Findings surface in three places on every PR: inline SARIF annotations in the diff, a sticky `wasaa-ci-report` PR comment, and a downloadable `wasaa-ci-report-<gate>` artifact containing an HTML dashboard.

## Deferred: Autofix loop (Claude sub-agent)

**PAUSED as of 2026-07-07.** The scaffolding remains in this repo but is not wired into any product repo. Product repos may opt into an automated fix loop *later* by wiring the `claude-autofix.yml` reusable workflow into their caller (see `templates/caller-with-autofix.yml`).

- **Trigger**: `ci-fast` failure on a PR. Never runs on `main` or on tags.
- **Bounded**: max 3 iterations per PR (tracked via commit markers `[wasaa-ci-autofix N]`).
- **Scope**: the agent can only Read/Edit/Write code files, and run a whitelisted set of Bash commands (test runners, formatters, `git status/diff`, `rg/grep/find`). It cannot `git push` directly — the workflow does that.
- **Guarded paths**: the agent is instructed AND the workflow enforces that it cannot commit changes to `.github/workflows/**`, `.wasaa-ci-waiver.yml`, or `.wasaa-ci/**`. If it tries, those files are reverted before commit.
- **Playbook**: the agent's standing instructions live in `.claude/instructions/autofix.md` in this repo. They include the exact list of "right fix / wrong fix" patterns per finding type.
- **Escalation**: if iterations exhaust or findings require guarded-file changes, the agent posts a PR comment describing what a human needs to do (file a waiver, adjust a rule upstream, decide a policy trade-off) and stops.

**The autofix loop never lowers the gate.** It only changes product-repo code. Attempts to suppress findings via inline comments (`eslint-disable`, `nosec`, `nolint`, `# noqa`, etc.) or by widening types to `any`/`interface{}`/`dynamic` are explicitly forbidden in its playbook.

## Change management

- Threshold changes to this policy require sign-off from Security + Engineering leads.
- New rules are added in **advisory mode** for one release cycle before being promoted to blocking.
- Removals of blocking rules require a documented incident postmortem tie-in.
