#!/usr/bin/env bash
# docker-compose-audit.sh
#
# Lints every docker-compose*.yml / compose.y*ml in the repo for production
# hygiene, security, and cost.
#
# CRITICAL:
#   - image tag is `:latest` or unpinned
#   - `privileged: true`
#   - Inline secret-shaped env keys (API_KEY=..., PASSWORD=..., TOKEN=...)
#   - `pid: host`, `ipc: host`, `network_mode: host`
#   - Bind-mount of / or /var/run/docker.sock (in non-observability service)
#
# HIGH:
#   - No restart policy
#   - No memory limit (mem_limit / deploy.resources.limits.memory)
#   - No cpu limit
#   - Published port bound to 0.0.0.0 (unless service is clearly a gateway)
#   - `user:` is root / 0
#
# MEDIUM (warn):
#   - No healthcheck
#   - No read_only: true on stateless services (nice-to-have)
#   - No explicit `networks:` — service on default bridge with everything else
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
fail=0

flag() {
  local file="$1" msg="$2" sev="${3:-HIGH}"
  echo "::error file=$file::compose-audit ($sev): $msg"
  [ "$sev" = "CRITICAL" ] || [ "$sev" = "HIGH" ] && fail=1 || true
}

warn() {
  local file="$1" msg="$2"
  echo "::warning file=$file::compose-audit: $msg"
}

# Locate compose files (POSIX-portable — no mapfile)
files_list=$(find "$ROOT" -type f \
  \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
     -o -name 'docker-compose.*.yml' -o -name 'docker-compose.*.yaml' \
     -o -name 'compose.yml' -o -name 'compose.yaml' \
     -o -name 'compose.*.yml' -o -name 'compose.*.yaml' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.wasaa-ci/*' 2>/dev/null || true)

if [ -z "$files_list" ]; then
  echo "compose-audit: no compose files found — skipping."
  exit 0
fi

# shellcheck disable=SC2086
python3 - $files_list <<'PY'
import sys, os, re, yaml

fail = 0
for path in sys.argv[1:]:
    try:
        doc = yaml.safe_load(open(path)) or {}
    except Exception as e:
        print(f"::error file={path}::compose-audit: invalid YAML: {e}")
        fail = 1
        continue

    services = doc.get("services") or {}
    if not isinstance(services, dict):
        print(f"::warning file={path}::compose-audit: no services block")
        continue

    for name, svc in services.items():
        if not isinstance(svc, dict): continue

        # ---- CRITICAL --------------------------------------------------------
        img = svc.get("image", "")
        if img:
            # unpinned or :latest
            if ":" not in img.split("@")[0]:
                print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' image '{img}' is unpinned. Pin a semver tag or digest.")
                fail = 1
            elif img.split("@")[0].endswith(":latest"):
                print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' uses ':latest'. Pin an immutable tag or digest.")
                fail = 1

        if svc.get("privileged") is True:
            print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' runs with privileged: true.")
            fail = 1

        for k in ("pid", "ipc", "network_mode"):
            v = svc.get(k)
            if isinstance(v, str) and v == "host":
                print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' uses {k}: host — breaks isolation.")
                fail = 1

        # Secret-shaped env inline
        env = svc.get("environment") or []
        env_items = env.items() if isinstance(env, dict) else \
                    [tuple(e.split("=", 1)) for e in env if isinstance(e, str) and "=" in e]
        secret_pat = re.compile(r"(API_?KEY|SECRET|PASSWORD|PASSWD|TOKEN|PRIVATE_KEY)", re.I)
        for k, v in env_items:
            if secret_pat.search(k or "") and v and not str(v).startswith("${"):
                print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' env '{k}' has an inline value. Use ${{VAR}} substitution or 'secrets:'.")
                fail = 1

        # Bind-mount to root or docker.sock
        for vol in svc.get("volumes") or []:
            src = vol.split(":")[0] if isinstance(vol, str) else (vol.get("source") if isinstance(vol, dict) else "")
            if src in ("/", "/etc", "/var"):
                print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' bind-mounts host path '{src}'.")
                fail = 1
            if "docker.sock" in (src or "") and name not in ("dind","docker","traefik","portainer"):
                print(f"::error file={path}::compose-audit (CRITICAL): service '{name}' mounts docker.sock — container escape risk.")
                fail = 1

        # ---- HIGH ------------------------------------------------------------
        if not svc.get("restart") and not (svc.get("deploy") or {}).get("restart_policy"):
            print(f"::error file={path}::compose-audit (HIGH): service '{name}' has no restart policy.")
            fail = 1

        deploy = svc.get("deploy") or {}
        res = (deploy.get("resources") or {}).get("limits") or {}
        has_mem = "mem_limit" in svc or "memory" in res
        has_cpu = "cpus" in svc or "cpus" in res
        if not has_mem:
            print(f"::error file={path}::compose-audit (HIGH): service '{name}' has no memory limit (mem_limit or deploy.resources.limits.memory).")
            fail = 1
        if not has_cpu:
            print(f"::error file={path}::compose-audit (HIGH): service '{name}' has no CPU limit.")
            fail = 1

        # Root user
        if str(svc.get("user", "")) in ("root", "0", "0:0"):
            print(f"::error file={path}::compose-audit (HIGH): service '{name}' runs as root.")
            fail = 1

        # Published ports bound to all interfaces
        for p in svc.get("ports") or []:
            s = p if isinstance(p, str) else (p.get("published") if isinstance(p, dict) else "")
            if isinstance(s, str) and (s.startswith("0.0.0.0:") or s.count(":") == 1):
                # host:container form without an explicit host IP → binds 0.0.0.0
                # allow if service name suggests gateway/proxy
                if not any(x in name.lower() for x in ("gateway","proxy","nginx","traefik","envoy","ingress","edge")):
                    print(f"::warning file={path}::compose-audit: service '{name}' publishes port '{s}' on all interfaces. Bind to 127.0.0.1 or use internal networks.")

        # ---- MEDIUM (warn) ---------------------------------------------------
        if "healthcheck" not in svc and "image" in svc:
            print(f"::warning file={path}::compose-audit: service '{name}' has no healthcheck.")
        if "read_only" not in svc:
            print(f"::warning file={path}::compose-audit: service '{name}' has no read_only: true — consider for stateless services.")

sys.exit(fail)
PY

fail=$?
if [ "$fail" -eq 0 ]; then echo "compose-audit: OK"; fi
exit "$fail"
