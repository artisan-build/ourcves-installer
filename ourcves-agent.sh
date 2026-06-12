# OurCVEs Bash agent — single self-contained install + report script.
#
# Modes:
#   sudo bash install.sh --token ouc_inst_XXXX [--if-not-installed]
#       First-time install: self-registers with the API, saves the
#       server-scoped agent token to /etc/ourcves/agent.conf, installs the
#       script to /usr/local/bin/ourcves-agent, wires up package-manager,
#       boot, and cron triggers, then runs an immediate report.
#
#   ourcves-agent [--trigger post_invoke|boot|cron|manual]
#       Report mode: reads the saved agent token and POSTs an inventory
#       snapshot to /api/v1/servers/ingest. Default trigger is `manual`.
#
#   sudo bash install.sh --update              (or: sudo ourcves-agent --update)
#       Reinstall in place: replaces /usr/local/bin/ourcves-agent with the
#       current version and re-wires the triggers, reusing the saved agent
#       token. Does NOT re-register (no duplicate server, no new token). This
#       is the one-time step to move an already-installed host onto a
#       self-update-capable version; after that the agent keeps itself current.
#
#   sudo bash install.sh --uninstall          (or: sudo ourcves-agent --uninstall)
#       Removes the installed binary, the saved agent token, the apt/dnf
#       hooks, the cron backstop, and the systemd boot unit. Leaves the
#       log file in place so operators can audit the last report before
#       cleaning it up themselves.
#
# Self-update: in report mode the agent reads the ingest response's `agent`
# hint and, when a newer signed release is published, downloads it, verifies
# its SHA-256 and detached signature against the embedded public key with the
# host's own openssl, syntax-checks it, and atomically replaces itself. It
# never updates from the apt/dnf post-invoke trigger (the package manager holds
# its lock) and backs off after a failure.
#
# Endpoints (see product-plan/architecture/architecture.md §8):
#   POST /api/v1/servers/register   (Authorization: Bearer ouc_inst_...)
#   POST /api/v1/servers/ingest     (Authorization: Bearer ouc_srv_...)
#   POST /api/v1/servers/lockfiles  (Authorization: Bearer ouc_srv_...)
#   GET  /agent/releases/latest     (signed release artifact for self-update)

set -euo pipefail

AGENT_VERSION="2026.06.10"
SELF_UPDATE_ENABLED="0"
API_BASE="${OURCVES_API_BASE:-http://ourcves.gro.sv/api/v1}"
INSTALL_URL="${OURCVES_INSTALL_URL:-https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh}"
UPDATE_URL="${OURCVES_UPDATE_URL:-https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh}"
CONFIG_FILE="/etc/ourcves/agent.conf"
STATE_FILE="/etc/ourcves/agent.state"
AGENT_BIN="/usr/local/bin/ourcves-agent"
CRON_FILE="/etc/cron.d/ourcves-agent"
APT_HOOK="/etc/apt/apt.conf.d/99ourcves"
DNF_HOOK="/etc/dnf/plugins/post-transaction-actions.d/ourcves.action"
SYSTEMD_UNIT="/etc/systemd/system/ourcves-agent.service"
LOG_FILE="/var/log/ourcves-agent.log"

# Colon-separated absolute directories to include in repository discovery in
# addition to /var/www, /srv, /opt, /home/forge, and /home/deploy.
OURCVES_REPO_DISCOVERY_PATHS="${OURCVES_REPO_DISCOVERY_PATHS:-}"

# Public key for verifying self-update signatures. The matching private key is
# held offline and never touches the platform; an empty key disables automatic
# self-update (fail-safe — manual --update still works).
read -r -d '' AGENT_PUBLIC_KEY <<'OURCVES_PUBKEY' || true
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvLq+AMJA4zSySQGY6kIi
WlQzU31rMTyYT2zRPjiwqX5DdWiQRrT4l1K1QG+9sAqryDrcLXqZxPdKX9+wQhc6
fe/2ZDy4gQrdcJ/dKR+QebQkbSa/59T6gq8bNQmrdq9bQ5FP13iplU5EZ0pP4afh
Q74hIHVPuQL4orN6nqDUd47wVNriLYBvlsXrSn9VSBtgT29AHK/mSvNs0ZIiO4KI
eh1zJyroIDguYt58K87w34iI+yhyXwtBfJStR3yc9rJPuRUgAn7/5A7/AO5VVlN3
9VUW3GxpUxLB9pzSfwkZW5x7FtJBrdHailVnt5Bu3J8eJ9IBVMHsJwlZNpC4syVa
AwIDAQAB
-----END PUBLIC KEY-----

OURCVES_PUBKEY

INSTALL_TOKEN=""
TRIGGER="manual"
IF_NOT_INSTALLED=0
UNINSTALL=0
UPDATE=0

# ── Arg parsing ───────────────────────────────────────────────────────────

while (( $# > 0 )); do
  case "$1" in
    --token)
      INSTALL_TOKEN="${2:-}"
      [[ -z "$INSTALL_TOKEN" ]] && { echo "OurCVEs: --token requires a value" >&2; exit 2; }
      shift 2
      ;;
    --trigger)
      TRIGGER="${2:-manual}"
      shift 2
      ;;
    --if-not-installed)
      IF_NOT_INSTALLED=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --update)
      UPDATE=1
      shift
      ;;
    --version)
      echo "ourcves-agent $AGENT_VERSION"
      exit 0
      ;;
    -h|--help)
      sed -n '2,24p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *)
      echo "OurCVEs: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$TRIGGER" in
  post_invoke|boot|cron|manual) ;;
  *) echo "OurCVEs: --trigger must be one of post_invoke/boot/cron/manual" >&2; exit 2 ;;
esac

# Load saved config (contains AGENT_TOKEN after first install)
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── Dependency checks ─────────────────────────────────────────────────────

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "OurCVEs: missing required command '$1'." >&2
    return 1
  }
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  echo "OurCVEs: jq not found — installing via the system package manager..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq jq
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q jq
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q jq
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "OurCVEs: 'jq' is required but could not be installed automatically." >&2
    exit 1
  }
}

# ── Helpers ───────────────────────────────────────────────────────────────

detect_display_name() {
  # Prefer cloud-provider instance name over raw hostname.
  # All metadata probes use tight connect timeouts — on a non-cloud host
  # these IPs/DNS names are unreachable and would otherwise hang for the
  # OS-level TCP SYN retry pattern (~2 minutes).
  local name=""

  # AWS EC2 (IMDSv2): the Name tag, if present.
  if TOKEN=$(curl -sf --connect-timeout 1 --max-time 2 \
       -X PUT "http://169.254.169.254/latest/api/token" \
       -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null); then
    name=$(curl -sf --connect-timeout 1 --max-time 2 \
      -H "X-aws-ec2-metadata-token: $TOKEN" \
      "http://169.254.169.254/latest/meta-data/tags/instance/Name" 2>/dev/null || true)
  fi

  # GCP: instance name from metadata server.
  [[ -z "$name" ]] && name=$(curl -sf --connect-timeout 1 --max-time 2 \
    "http://metadata.google.internal/computeMetadata/v1/instance/name" \
    -H "Metadata-Flavor: Google" 2>/dev/null || true)

  # Fallback: hostname (DigitalOcean droplets set this to the droplet name).
  [[ -z "$name" ]] && name=$(timeout 5 hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")

  echo "$name"
}

collect_packages() {
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='{"name":"${Package}","version":"${Version}","source":"dpkg"}\n' \
      | jq -s '.'
  elif command -v rpm >/dev/null 2>&1; then
    rpm -qa --queryformat '{"name":"%{NAME}","version":"%{VERSION}-%{RELEASE}","source":"rpm"}\n' \
      | jq -s '.'
  elif command -v apk >/dev/null 2>&1; then
    apk info -v 2>/dev/null \
      | awk '{
          n = match($0, /-[0-9]/);
          if (n > 0) {
            name = substr($0, 1, n-1);
            version = substr($0, n+1);
            printf "{\"name\":\"%s\",\"version\":\"%s\",\"source\":\"apk\"}\n", name, version;
          }
        }' \
      | jq -s '.'
  else
    echo "[]"
  fi
}

collect_reboot_packages() {
  # Echoes a JSON array of package names that flagged the reboot
  # requirement. Only Debian/Ubuntu exposes this (via the .pkgs marker
  # file); on other distros we return an empty array.
  if [[ -f /var/run/reboot-required.pkgs ]]; then
    jq -R -s -c 'split("\n") | map(select(length > 0))' \
      < /var/run/reboot-required.pkgs
  else
    echo "[]"
  fi
}

detect_reboot_required() {
  # Echoes "true" or "false".

  # Debian/Ubuntu: explicit marker file.
  [[ -f /var/run/reboot-required ]] && { echo "true"; return; }

  # RHEL/CentOS/Fedora: needs-restarting -r exits 1 when reboot is required.
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || { echo "true"; return; }
  fi

  # Cross-platform fallback: running kernel vs installed kernel package.
  local running installed
  running=$(uname -r)
  if command -v dpkg-query >/dev/null 2>&1; then
    installed=$(dpkg-query -W -f='${Version}\n' "linux-image-$running" 2>/dev/null || true)
    if [[ -z "$installed" ]]; then
      echo "true"
      return
    fi
  elif command -v rpm >/dev/null 2>&1; then
    installed=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}\n' 2>/dev/null | tail -n 1 || true)
    if [[ -n "$installed" && "$installed" != "$running" ]]; then
      echo "true"
      return
    fi
  fi

  echo "false"
}

# Collects globally-installed JS package managers and their global packages
# so the server can flag freshly-published global installs. Every shell-out
# is wrapped to never break the agent. Echoes a JSON object with `tools` and
# `global_packages` arrays.
collect_hygiene() {
  local tools='[]' globals='[]'

  if command -v npm >/dev/null 2>&1; then
    local npm_version npm_min npm_globals tool_json
    npm_version=$(npm --version 2>/dev/null || echo "")
    npm_min=$(npm config get minimum-release-age 2>/dev/null || echo null)
    [[ -z "$npm_min" || "$npm_min" == "undefined" ]] && npm_min=null
    tool_json=$(jq -n --arg n "npm" --arg v "$npm_version" --argjson m "$npm_min" \
      '{name:$n,version:$v,minimum_release_age:$m}')
    tools=$(jq -c --argjson t "$tool_json" '. + [$t]' <<<"$tools")
    npm_globals=$(npm ls -g --json --depth=0 2>/dev/null | jq -c '
      (.dependencies // {}) | to_entries | map({tool:"npm", name:.key, version:(.value.version // "")})
    ' 2>/dev/null || echo "[]")
    globals=$(jq -c --argjson g "$npm_globals" '. + $g' <<<"$globals")
  fi

  if command -v pnpm >/dev/null 2>&1; then
    local pnpm_version pnpm_min pnpm_globals tool_json
    pnpm_version=$(pnpm --version 2>/dev/null || echo "")
    pnpm_min=$(pnpm config get minimum-release-age 2>/dev/null || echo null)
    [[ -z "$pnpm_min" || "$pnpm_min" == "undefined" ]] && pnpm_min=null
    tool_json=$(jq -n --arg n "pnpm" --arg v "$pnpm_version" --argjson m "$pnpm_min" \
      '{name:$n,version:$v,minimum_release_age:$m}')
    tools=$(jq -c --argjson t "$tool_json" '. + [$t]' <<<"$tools")
    pnpm_globals=$(pnpm ls -g --json --depth=0 2>/dev/null | jq -c '
      [.[]?.dependencies? // {} | to_entries[] | {tool:"pnpm", name:.key, version:(.value.version // "")}]
    ' 2>/dev/null || echo "[]")
    globals=$(jq -c --argjson g "$pnpm_globals" '. + $g' <<<"$globals")
  fi

  if command -v yarn >/dev/null 2>&1; then
    local yarn_version yarn_min tool_json
    yarn_version=$(yarn --version 2>/dev/null || echo "")
    yarn_min=$(yarn config get npmMinimalAgeGate 2>/dev/null || echo null)
    [[ -z "$yarn_min" || "$yarn_min" == "undefined" ]] && yarn_min=null
    tool_json=$(jq -n --arg n "yarn" --arg v "$yarn_version" --argjson m "$yarn_min" \
      '{name:$n,version:$v,minimum_release_age:$m}')
    tools=$(jq -c --argjson t "$tool_json" '. + [$t]' <<<"$tools")
  fi

  if command -v bun >/dev/null 2>&1; then
    local bun_version tool_json
    bun_version=$(bun --version 2>/dev/null || echo "")
    tool_json=$(jq -n --arg n "bun" --arg v "$bun_version" --argjson m null \
      '{name:$n,version:$v,minimum_release_age:$m}')
    tools=$(jq -c --argjson t "$tool_json" '. + [$t]' <<<"$tools")
  fi

  jq -nc --argjson tools "$tools" --argjson globals "$globals" \
    '{tools:$tools, global_packages:$globals}'
}

# Append a string to a JSON array string and echo the result. Keeps coverage
# bookkeeping bash-version-safe (no array-with-set-u pitfalls).
pp_push() {
  jq -c --arg v "$2" '. + [$v]' <<<"$1"
}

# Collects the OS patch posture (auto-patch, auto-reboot, schedule, pending
# reboot, kernel delta, livepatch, Ubuntu Pro/ESM, needrestart, OS) for
# Debian/Ubuntu (apt) and RHEL (dnf). Every probe is wrapped so a missing tool
# or unreadable file degrades to a coverage gap rather than aborting the agent.
# Non-apt/dnf hosts report posture_supported:false so the server never reads a
# null-filled object as "nothing configured". Echoes a JSON object.
collect_patch_posture() {
  local unreadable='[]' not_applicable='[]'

  # ── OS + kernel (distro-agnostic; kernel reported raw, compared server-side) ─
  local os_id="" os_version="" os_codename=""
  if [[ -r /etc/os-release ]]; then
    os_id=$( . /etc/os-release 2>/dev/null && echo "${ID:-}" )
    os_version=$( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}" )
    os_codename=$( . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" )
  fi
  local os_json
  os_json=$(jq -nc --arg id "$os_id" --arg v "$os_version" --arg c "$os_codename" \
    '{id:$id, version:$v, codename:$c}')

  local running latest_installed=""
  running=$(uname -r 2>/dev/null || echo "")
  if command -v dpkg-query >/dev/null 2>&1; then
    latest_installed=$(dpkg-query -W -f='${Version}\n' 'linux-image-[0-9]*' 2>/dev/null \
      | sort -V | tail -n1 || echo "")
  elif command -v rpm >/dev/null 2>&1; then
    latest_installed=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}\n' 2>/dev/null \
      | sort -V | tail -n1 || echo "")
  fi
  local kernel_json
  kernel_json=$(jq -nc --arg r "$running" --arg l "$latest_installed" \
    '{running:$r} + ($l | if . == "" then {} else {latest_installed:.} end)')

  # Determine the patch mechanism.
  local mechanism=""
  if command -v apt-config >/dev/null 2>&1; then
    mechanism="apt"
  elif command -v dnf >/dev/null 2>&1; then
    mechanism="dnf"
  fi

  if [[ -z "$mechanism" ]]; then
    jq -nc --argjson os "$os_json" --argjson kernel "$kernel_json" \
      '{posture_supported:false, os:$os, kernel:$kernel}'
    return 0
  fi

  # ── Reboot pending (shared) ───────────────────────────────────────────────
  local rp_required=false rp_since=""
  if [[ -f /var/run/reboot-required ]]; then
    rp_required=true
    rp_since=$(stat -c '%y' /var/run/reboot-required 2>/dev/null | sed 's/ /T/; s/\([0-9]\)\.\([0-9]*\) /\1/' | cut -d'.' -f1 || echo "")
  elif command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || rp_required=true
  fi
  local reboot_json
  reboot_json=$(jq -nc --argjson req "$rp_required" --arg since "$rp_since" --argjson pkgs "$(collect_reboot_packages)" \
    '{required:$req, packages:$pkgs} + ($since | if . == "" then {} else {since:.} end)')

  # ── Auto-patch + auto-reboot + schedule ───────────────────────────────────
  local ap_mech ap_status="detected" ap_enabled=false ap_last_run_ok=null ap_last_run_at=""
  local ar_status="detected" ar_enabled=false ar_time=""
  local timer_unit svc_unit

  if [[ "$mechanism" == "apt" ]]; then
    ap_mech="unattended-upgrades"
    timer_unit="apt-daily-upgrade.timer"
    svc_unit="apt-daily-upgrade.service"
    local apt_conf=""
    if apt_conf=$(apt-config dump 2>/dev/null); then
      grep -qiE 'APT::Periodic::Unattended-Upgrade "[1-9]' <<<"$apt_conf" && ap_enabled=true
      grep -qiE 'Unattended-Upgrade::Automatic-Reboot "true"' <<<"$apt_conf" && ar_enabled=true
      ar_time=$(grep -iE 'Unattended-Upgrade::Automatic-Reboot-Time' <<<"$apt_conf" | grep -oE '"[^"]*"' | head -n1 | tr -d '"' || echo "")
    else
      ap_status="unreadable"; unreadable=$(pp_push "$unreadable" "apt-config")
    fi
  else
    ap_mech="dnf-automatic"
    timer_unit="dnf-automatic.timer"
    svc_unit="dnf-automatic.service"
    if [[ -r /etc/dnf/automatic.conf ]]; then
      grep -qiE '^\s*apply_updates\s*=\s*yes' /etc/dnf/automatic.conf && ap_enabled=true
      grep -qiE '^\s*reboot\s*=\s*when-needed' /etc/dnf/automatic.conf && ar_enabled=true
    else
      ap_status="unreadable"; unreadable=$(pp_push "$unreadable" "dnf-automatic-config")
    fi
  fi

  # Cross-check the timer is actually enabled; a masked timer means config-on
  # but never-runs, which must not read as enabled.
  local timer_enabled=false timer_active=false next_run=""
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled "$timer_unit" >/dev/null 2>&1 && timer_enabled=true
    systemctl is-active "$timer_unit" >/dev/null 2>&1 && timer_active=true
    [[ "$timer_enabled" == "true" ]] || ap_enabled=false
    next_run=$(systemctl show "$timer_unit" -p NextElapseUSecRealtime --value 2>/dev/null || echo "")
    [[ "$next_run" == "n/a" ]] && next_run=""

    local exit_status exit_ts
    exit_status=$(systemctl show "$svc_unit" -p ExecMainStatus --value 2>/dev/null || echo "")
    if [[ -n "$exit_status" ]]; then
      [[ "$exit_status" == "0" ]] && ap_last_run_ok=true || ap_last_run_ok=false
    fi
    exit_ts=$(systemctl show "$svc_unit" -p ExecMainExitTimestamp --value 2>/dev/null || echo "")
    if [[ -n "$exit_ts" && "$exit_ts" != "n/a" ]]; then
      ap_last_run_at=$(date -d "$exit_ts" --iso-8601=seconds 2>/dev/null || echo "")
    fi
  else
    unreadable=$(pp_push "$unreadable" "systemd")
  fi

  local auto_patch_json auto_reboot_json schedule_json
  auto_patch_json=$(jq -nc --arg mech "$ap_mech" --arg status "$ap_status" \
    --argjson enabled "$ap_enabled" --argjson ok "$ap_last_run_ok" --arg last "$ap_last_run_at" \
    '{mechanism:$mech, status:$status, enabled:$enabled, last_run_ok:$ok} + ($last | if . == "" then {} else {last_run_at:.} end)')
  auto_reboot_json=$(jq -nc --arg mech "$ap_mech" --arg status "$ar_status" \
    --argjson enabled "$ar_enabled" --arg time "$ar_time" \
    '{mechanism:$mech, status:$status, enabled:$enabled} + ($time | if . == "" then {} else {time:.} end)')
  schedule_json=$(jq -nc --argjson te "$timer_enabled" --argjson ta "$timer_active" --arg next "$next_run" \
    '{timer_enabled:$te, timer_active:$ta} + ($next | if . == "" then {} else {next_run_at:.} end)')

  # ── Livepatch ─────────────────────────────────────────────────────────────
  local lp_status="not_applicable" lp_enabled=false
  if command -v canonical-livepatch >/dev/null 2>&1; then
    lp_status="detected"
    canonical-livepatch status 2>/dev/null | grep -qiE 'running:\s*true' && lp_enabled=true
  else
    not_applicable=$(pp_push "$not_applicable" "livepatch")
  fi
  local livepatch_json
  livepatch_json=$(jq -nc --arg status "$lp_status" --argjson enabled "$lp_enabled" \
    '{provider:"canonical-livepatch", status:$status, enabled:$enabled}')

  # ── Ubuntu Pro / ESM ──────────────────────────────────────────────────────
  local up_status="not_applicable" up_attached=false up_infra=false
  if command -v pro >/dev/null 2>&1; then
    up_status="detected"
    local pro_json=""
    if pro_json=$(pro status --format json 2>/dev/null); then
      jq -e '.attached == true' <<<"$pro_json" >/dev/null 2>&1 && up_attached=true
      jq -e '.services[]? | select(.name=="esm-infra" and .status=="enabled")' <<<"$pro_json" >/dev/null 2>&1 && up_infra=true
    else
      up_status="unreadable"; unreadable=$(pp_push "$unreadable" "ubuntu-pro")
    fi
  else
    not_applicable=$(pp_push "$not_applicable" "ubuntu_pro")
  fi
  local ubuntu_pro_json
  ubuntu_pro_json=$(jq -nc --arg status "$up_status" --argjson attached "$up_attached" --argjson infra "$up_infra" \
    '{status:$status, attached:$attached, esm_infra:$infra}')

  # ── needrestart ───────────────────────────────────────────────────────────
  local nr_installed=false nr_mode="unknown"
  if command -v needrestart >/dev/null 2>&1; then
    nr_installed=true
    if [[ -r /etc/needrestart/needrestart.conf ]]; then
      local nr_raw
      nr_raw=$(grep -oE "nrconf\{restart\}\s*=\s*'[ali]'" /etc/needrestart/needrestart.conf 2>/dev/null | grep -oE "'[ali]'" | tr -d "'" | head -n1 || echo "")
      case "$nr_raw" in
        a) nr_mode="auto" ;;
        l) nr_mode="list" ;;
        i) nr_mode="interactive" ;;
      esac
    fi
  fi
  local needrestart_json
  needrestart_json=$(jq -nc --argjson installed "$nr_installed" --arg mode "$nr_mode" \
    '{installed:$installed, mode:$mode}')

  # ── Assemble ──────────────────────────────────────────────────────────────
  jq -nc \
    --argjson auto_patch "$auto_patch_json" \
    --argjson auto_reboot "$auto_reboot_json" \
    --argjson schedule "$schedule_json" \
    --argjson reboot_pending "$reboot_json" \
    --argjson kernel "$kernel_json" \
    --argjson livepatch "$livepatch_json" \
    --argjson ubuntu_pro "$ubuntu_pro_json" \
    --argjson needrestart "$needrestart_json" \
    --argjson os "$os_json" \
    --argjson unreadable "$unreadable" \
    --argjson not_applicable "$not_applicable" \
    '{posture_supported:true,
      auto_patch:$auto_patch,
      auto_reboot:$auto_reboot,
      schedule:$schedule,
      reboot_pending:$reboot_pending,
      kernel:$kernel,
      livepatch:$livepatch,
      ubuntu_pro:$ubuntu_pro,
      needrestart:$needrestart,
      os:$os,
      coverage:{unreadable:$unreadable, not_applicable:$not_applicable}}'
}

# Collects deployed plain-clone repositories by reading .git/config directly.
# Worktrees (.git files) and bare repositories are intentionally not detected.
# Echoes {repos:[{host,vendor,repo,path}], truncated:bool}. Never emits URLs.
collect_repo_inventory() {
  local repos='[]' truncated=false count=0
  local roots=(/var/www /srv /opt /home/forge /home/deploy)

  if [[ -n "${OURCVES_REPO_DISCOVERY_PATHS:-}" ]]; then
    local extra_path
    while IFS= read -r extra_path; do
      [[ -n "$extra_path" ]] && roots+=("$extra_path")
    done < <(tr ':' '\n' <<<"$OURCVES_REPO_DISCOVERY_PATHS" 2>/dev/null || true)
  fi

  repo_remote_url() {
    local config="$1"
    [[ -r "$config" ]] || return 1

    awk '
      /^[[:space:]]*\[remote[[:space:]]+"[^"]+"\][[:space:]]*$/ {
        remote=$0
        sub(/^[[:space:]]*\[remote[[:space:]]+"/, "", remote)
        sub(/"\][[:space:]]*$/, "", remote)
        next
      }
      remote != "" && /^[[:space:]]*url[[:space:]]*=/ {
        url=$0
        sub(/^[^=]*=[[:space:]]*/, "", url)
        if (remote == "origin") {
          origin=url
          exit
        }
        if (first == "") {
          first=url
        }
      }
      END {
        if (origin != "") {
          print origin
        } else if (first != "") {
          print first
        }
      }
    ' "$config" 2>/dev/null || return 1
  }

  repo_head_sha() {
    local git_dir="$1" head ref sha
    [[ -r "$git_dir/HEAD" ]] || return 1

    IFS= read -r head < "$git_dir/HEAD" || return 1
    head="${head%$'\r'}"

    if [[ "$head" == ref:* ]]; then
      ref="${head#ref:}"
      ref="${ref#${ref%%[![:space:]]*}}"
      [[ "$ref" == refs/* && "$ref" != *..* && "$ref" != *//* && "$ref" != *$'\\'* && "$ref" =~ ^refs/[A-Za-z0-9._/-]+$ ]] || return 1

      if [[ -r "$git_dir/$ref" ]]; then
        IFS= read -r sha < "$git_dir/$ref" || return 1
      elif [[ -r "$git_dir/packed-refs" ]]; then
        sha=$(awk -v ref="$ref" '
          {
            packed_ref=$2
            sub(/\r$/, "", packed_ref)
          }
          packed_ref == ref && $1 ~ /^[0-9A-Fa-f]+$/ && (length($1) == 40 || length($1) == 64) {
            print $1
            exit
          }
        ' "$git_dir/packed-refs" 2>/dev/null || true)
      fi
    else
      sha="$head"
    fi

    sha="${sha%$'\r'}"
    case "${#sha}" in
      40|64) ;;
      *) return 1 ;;
    esac
    [[ "$sha" == *[!0-9A-Fa-f]* ]] && return 1

    printf '%s\n' "$sha"
  }

  repo_lockfile_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" | awk '{print $1}'
    else
      openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
  }

  collect_repo_lockfiles() {
    local repo_path="$1" lockfiles='[]' rel_path kind path sha item

    for rel_path in composer.lock package-lock.json pnpm-lock.yaml yarn.lock; do
      path="$repo_path/$rel_path"
      [[ -f "$path" && -r "$path" ]] || continue

      case "$rel_path" in
        composer.lock) kind="composer" ;;
        package-lock.json) kind="npm" ;;
        pnpm-lock.yaml) kind="pnpm" ;;
        yarn.lock) kind="yarn" ;;
        *) continue ;;
      esac

      sha=$(repo_lockfile_sha256 "$path" 2>/dev/null || true)
      [[ ${#sha} -eq 64 && "$sha" != *[!0-9A-Fa-f]* ]] || continue

      item=$(jq -nc --arg rel_path "$rel_path" --arg kind "$kind" --arg sha256 "$sha" \
        '{rel_path:$rel_path, kind:$kind, sha256:$sha256}' 2>/dev/null || true)
      [[ -n "$item" ]] || continue

      lockfiles=$(jq -c --argjson lockfile "$item" '. + [$lockfile]' <<<"$lockfiles" 2>/dev/null || echo "[]")
    done

    echo "$lockfiles"
  }

  repo_json_from_url() {
    local url="$1" path="$2"
    local without_scheme authority host path_part vendor repo remainder

    [[ -n "$url" && -n "$path" ]] || return 1

    if [[ "$url" == *"://"* ]]; then
      without_scheme="${url#*://}"
      authority="${without_scheme%%/*}"
      path_part="${without_scheme#*/}"
      host="${authority#*@}"
      host="${host%%:*}"
    elif [[ "$url" == *:* ]]; then
      authority="${url%%:*}"
      path_part="${url#*:}"
      host="${authority#*@}"
    else
      return 1
    fi

    path_part="${path_part%%\?*}"
    path_part="${path_part%%#*}"
    path_part="${path_part#/}"
    vendor="${path_part%%/*}"
    remainder="${path_part#*/}"
    repo="${remainder%%/*}"
    repo="${repo%.git}"

    [[ -n "$host" && -n "$vendor" && -n "$repo" ]] || return 1
    [[ "$host" != *"@"* && "$vendor" != *"@"* && "$repo" != *"@"* ]] || return 1
    [[ "$host" != *"://"* && "$vendor" != *"://"* && "$repo" != *"://"* ]] || return 1

    jq -nc --arg host "$host" --arg vendor "$vendor" --arg repo "$repo" --arg path "$path" \
      '{host:$host, vendor:$vendor, repo:$repo, path:$path}' 2>/dev/null || return 1
  }

  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue

    local git_dir
    while IFS= read -r git_dir; do
      [[ -d "$git_dir" ]] || continue

      local repo_path config url item head_sha lockfiles
      repo_path="${git_dir%/.git}"
      config="$git_dir/config"
      url=$(repo_remote_url "$config" 2>/dev/null || true)
      [[ -n "$url" ]] || continue
      item=$(repo_json_from_url "$url" "$repo_path" 2>/dev/null || true)
      [[ -n "$item" ]] || continue
      head_sha=$(repo_head_sha "$git_dir" 2>/dev/null || true)
      item=$(jq -c --arg head_sha "$head_sha" '. + {head_sha:(if $head_sha == "" then null else $head_sha end)}' <<<"$item" 2>/dev/null || echo "$item")
      lockfiles=$(collect_repo_lockfiles "$repo_path" 2>/dev/null || echo "[]")
      item=$(jq -c --argjson lockfiles "$lockfiles" '. + {lockfiles:$lockfiles}' <<<"$item" 2>/dev/null || echo "$item")

      if (( count >= 100 )); then
        truncated=true
        break
      fi

      repos=$(jq -c --argjson repo "$item" '. + [$repo]' <<<"$repos" 2>/dev/null || echo "[]")
      count=$(( count + 1 ))
    done < <(find "$root" -maxdepth 6 \
      \( -type d \( -name node_modules -o -name vendor -o -name .cache \) -prune \) -o \
      \( -type d -name .git -print -prune \) 2>/dev/null || true)

    [[ "$truncated" == "true" ]] && break
  done

  jq -nc --argjson repos "$repos" --argjson truncated "$truncated" \
    '{repos:$repos, truncated:$truncated}' 2>/dev/null || echo '{"repos":[],"truncated":false}'
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "OurCVEs: this step requires root. Re-run with sudo." >&2
    exit 1
  fi
}

install_self_to_bin() {
  # When invoked via `curl | bash`, $0 is "bash" — re-download from the
  # canonical URL instead of trying to copy a non-existent file.
  if [[ -f "$0" && "$0" != "bash" ]]; then
    install -m 0755 "$0" "$AGENT_BIN"
  else
    curl -sSL --connect-timeout 5 --max-time 30 "$INSTALL_URL" -o "$AGENT_BIN"
    chmod 0755 "$AGENT_BIN"
  fi
}

# ── Self-update ─────────────────────────────────────────────────────────────

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  fi
}

file_size_bytes() {
  stat -c '%s' "$1" 2>/dev/null || wc -c < "$1" | tr -d '[:space:]'
}

upload_needed_lockfiles() {
  [[ -f /tmp/ourcves_response.json ]] || return 0

  local needed_count
  needed_count=$(jq -r '(.needed_lockfiles // []) | length' /tmp/ourcves_response.json 2>/dev/null || echo 0)
  [[ "$needed_count" =~ ^[0-9]+$ ]] || needed_count=0
  (( needed_count > 0 )) || return 0

  while IFS= read -r needed; do
    local repo_path rel_path kind sha file_path size actual_sha
    repo_path=$(jq -r '.path // empty' <<<"$needed" 2>/dev/null || echo "")
    rel_path=$(jq -r '.rel_path // empty' <<<"$needed" 2>/dev/null || echo "")
    kind=$(jq -r '.kind // empty' <<<"$needed" 2>/dev/null || echo "")
    sha=$(jq -r '.sha256 // empty' <<<"$needed" 2>/dev/null || echo "")
    [[ -n "$repo_path" && -n "$rel_path" && -n "$kind" && -n "$sha" ]] || continue

    file_path="$repo_path/$rel_path"
    [[ -f "$file_path" && -r "$file_path" ]] || continue

    size=$(file_size_bytes "$file_path" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    (( size <= 8388608 )) || continue

    actual_sha=$(sha256_of "$file_path" 2>/dev/null || echo "")
    [[ "$actual_sha" == "$sha" ]] || continue

    jq -n \
      --arg path "$repo_path" \
      --arg rel_path "$rel_path" \
      --arg kind "$kind" \
      --arg sha256 "$sha" \
      --rawfile content "$file_path" \
      '{path:$path, rel_path:$rel_path, kind:$kind, sha256:$sha256, content:$content}' 2>/dev/null \
      | curl -s --connect-timeout 5 --max-time 60 \
          -o /dev/null \
          -X POST "$API_BASE/servers/lockfiles" \
          -H "Authorization: Bearer $AGENT_TOKEN" \
          -H "Content-Type: application/json" \
          --data-binary @- >/dev/null 2>&1 || true
  done < <(jq -c '(.needed_lockfiles // [])[]' /tmp/ourcves_response.json 2>/dev/null || true)
}

# True when $1 is a strictly newer version than $2 (sortable YYYY.MM.DD).
version_gt() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

update_backoff_active() {
  [[ -f "$STATE_FILE" ]] || return 1
  local LAST_FAILED_VERSION="" LAST_FAILED_AT=0
  source "$STATE_FILE" 2>/dev/null || true
  [[ "$LAST_FAILED_VERSION" == "$1" ]] || return 1
  local now; now=$(date +%s 2>/dev/null || echo 0)
  (( now - LAST_FAILED_AT < 21600 ))   # 6h backoff per failing version
}

record_update_failure() {
  echo "OurCVEs: self-update to $1 failed: $2" | tee -a "$LOG_FILE" >&2
  mkdir -p /etc/ourcves 2>/dev/null || true
  { echo "LAST_FAILED_VERSION=$1"; echo "LAST_FAILED_AT=$(date +%s 2>/dev/null || echo 0)"; } > "$STATE_FILE" 2>/dev/null || true
}

# Read the ingest response's update hint and, if a newer signed release is
# offered, verify (sha256 + detached signature against the embedded public key)
# and atomically replace this script. Always returns 0 — a failed update must
# never break the agent's normal operation. The new version runs on the next
# trigger; we never exec freshly-downloaded code in-place.
attempt_self_update() {
  local trigger="$1"

  # Never update mid-apt/dnf: that trigger fires while the package manager
  # holds its lock.
  [[ "$trigger" == "post_invoke" ]] && return 0
  [[ "$SELF_UPDATE_ENABLED" == "1" ]] || return 0
  # No baked-in public key -> automatic update disabled (fail-safe).
  [[ -z "${AGENT_PUBLIC_KEY//[$' \t\r\n']/}" ]] && return 0
  command -v openssl >/dev/null 2>&1 || return 0
  [[ -f /tmp/ourcves_response.json ]] || return 0

  local status latest url sha sig
  status=$(jq -r '.agent.status // "current"' /tmp/ourcves_response.json 2>/dev/null || echo "current")
  [[ "$status" == "update_available" ]] || return 0
  latest=$(jq -r '.agent.latest_version // empty' /tmp/ourcves_response.json 2>/dev/null || echo "")
  url=$(jq -r '.agent.url // empty' /tmp/ourcves_response.json 2>/dev/null || echo "")
  sha=$(jq -r '.agent.sha256 // empty' /tmp/ourcves_response.json 2>/dev/null || echo "")
  sig=$(jq -r '.agent.signature // empty' /tmp/ourcves_response.json 2>/dev/null || echo "")
  [[ -n "$latest" && -n "$url" && -n "$sha" && -n "$sig" ]] || return 0

  version_gt "$latest" "$AGENT_VERSION" || return 0
  update_backoff_active "$latest" && return 0

  echo "OurCVEs: update available ($AGENT_VERSION -> $latest); verifying..." | tee -a "$LOG_FILE"

  local tmp sigfile pubfile
  tmp=$(mktemp) || return 0
  sigfile=$(mktemp) || { rm -f "$tmp"; return 0; }
  pubfile=$(mktemp) || { rm -f "$tmp" "$sigfile"; return 0; }
  trap 'rm -f "$tmp" "$sigfile" "$pubfile"' RETURN

  curl -sSL --connect-timeout 5 --max-time 60 "$url" -o "$tmp" \
    || { record_update_failure "$latest" "download failed"; return 0; }

  [[ "$(sha256_of "$tmp")" == "$sha" ]] \
    || { record_update_failure "$latest" "sha256 mismatch"; return 0; }

  printf '%s\n' "$AGENT_PUBLIC_KEY" > "$pubfile"
  printf '%s' "$sig" | base64 -d > "$sigfile" 2>/dev/null \
    || { record_update_failure "$latest" "bad signature encoding"; return 0; }
  openssl dgst -sha256 -verify "$pubfile" -signature "$sigfile" "$tmp" >/dev/null 2>&1 \
    || { record_update_failure "$latest" "signature verification failed"; return 0; }

  bash -n "$tmp" >/dev/null 2>&1 \
    || { record_update_failure "$latest" "syntax check failed"; return 0; }
  grep -q "OurCVEs Bash agent" "$tmp" \
    || { record_update_failure "$latest" "expected marker missing"; return 0; }
  grep -q "AGENT_VERSION=\"$latest\"" "$tmp" \
    || { record_update_failure "$latest" "version marker mismatch"; return 0; }

  # Atomic replace: stage on the same filesystem, then rename over the binary
  # (the running shell keeps the old inode open until it exits).
  local staged="${AGENT_BIN}.next.$$"
  install -m 0755 "$tmp" "$staged" 2>/dev/null \
    || { record_update_failure "$latest" "staging failed"; return 0; }
  mv -f "$staged" "$AGENT_BIN" 2>/dev/null \
    || { rm -f "$staged"; record_update_failure "$latest" "atomic replace failed"; return 0; }

  rm -f "$STATE_FILE" 2>/dev/null || true
  echo "OurCVEs: updated to $latest. It takes effect on the next trigger." | tee -a "$LOG_FILE"
  return 0
}

# Manual in-place reinstall (the --update flag). Operator-initiated over TLS —
# same trust as the original `curl | bash` install — so it does not require a
# signature; it just fetches the current script, syntax-checks it, replaces the
# binary, refreshes triggers, and reuses the saved token (no re-registration).
do_update() {
  require_root
  [[ -f "$CONFIG_FILE" ]] || {
    echo "OurCVEs: not installed (no $CONFIG_FILE). Run with --token to install first." >&2
    exit 1
  }
  ensure_jq
  require_cmd curl

  local tmp; tmp=$(mktemp)
  echo "OurCVEs: fetching the latest agent..."
  curl -sSL --connect-timeout 5 --max-time 60 "$INSTALL_URL" -o "$tmp" \
    || { echo "OurCVEs: download failed." >&2; rm -f "$tmp"; exit 1; }
  bash -n "$tmp" >/dev/null 2>&1 \
    || { echo "OurCVEs: downloaded script failed syntax check; not installing." >&2; rm -f "$tmp"; exit 1; }
  install -m 0755 "$tmp" "$AGENT_BIN"
  rm -f "$tmp"

  echo "OurCVEs: refreshing triggers (cron / apt / dnf / systemd)..."
  install_cron_backstop
  install_apt_hook
  install_dnf_hook
  install_systemd_boot_hook
  echo "OurCVEs: updated to $AGENT_VERSION. Sending a report..."
}

install_cron_backstop() {
  # Daily 03:MM with random minute, written to /etc/cron.d/ourcves-agent.
  local minute=$(( RANDOM % 60 ))
  cat > "$CRON_FILE" <<EOF
# OurCVEs agent — daily backstop. The package-manager and boot hooks are the
# primary triggers; this catches the long tail.
$minute 3 * * * root $AGENT_BIN --trigger cron >> $LOG_FILE 2>&1
EOF
  chmod 0644 "$CRON_FILE"
}

install_apt_hook() {
  command -v apt-get >/dev/null 2>&1 || return 0
  cat > "$APT_HOOK" <<EOF
// OurCVEs agent — fire after every apt/dpkg operation.
DPkg::Post-Invoke { "$AGENT_BIN --trigger post_invoke >> $LOG_FILE 2>&1 || true"; };
EOF
  chmod 0644 "$APT_HOOK"
}

install_dnf_hook() {
  command -v dnf >/dev/null 2>&1 || return 0
  # post-transaction-actions plugin: run a command after any transaction.
  # The plugin ships with dnf-plugins-core on most distros.
  mkdir -p "$(dirname "$DNF_HOOK")"
  cat > "$DNF_HOOK" <<EOF
# OurCVEs agent — fire after every dnf transaction.
*:any:$AGENT_BIN --trigger post_invoke >> $LOG_FILE 2>&1
EOF
  chmod 0644 "$DNF_HOOK"
}

install_systemd_boot_hook() {
  command -v systemctl >/dev/null 2>&1 || return 0
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=OurCVEs agent — report at boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT_BIN --trigger boot

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable ourcves-agent.service >/dev/null 2>&1 || true
}

do_uninstall() {
  # Removes every file the install flow wrote. Idempotent — re-running on a
  # half-uninstalled host is safe. We deliberately keep $LOG_FILE so the
  # operator can audit the last report before they remove it themselves.
  echo "OurCVEs: removing agent..."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable ourcves-agent.service >/dev/null 2>&1 || true
  fi
  rm -f "$SYSTEMD_UNIT"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$APT_HOOK"
  rm -f "$DNF_HOOK"
  rm -f "$CRON_FILE"
  rm -f "$AGENT_BIN"
  rm -f "$CONFIG_FILE"
  rmdir /etc/ourcves 2>/dev/null || true

  echo "OurCVEs: uninstall complete. Log file at $LOG_FILE was left in place."
}

# ── Uninstall flow ────────────────────────────────────────────────────────

if (( UNINSTALL )); then
  require_root
  do_uninstall
  exit 0
fi

# ── Manual update flow ────────────────────────────────────────────────────

if (( UPDATE )); then
  do_update
  # Fall through to report mode using the token already in CONFIG_FILE.
fi

# ── Install + register flow ───────────────────────────────────────────────

if [[ -n "$INSTALL_TOKEN" ]]; then
  require_root

  if (( IF_NOT_INSTALLED )) && [[ -x "$AGENT_BIN" && -f "$CONFIG_FILE" ]]; then
    echo "OurCVEs: already installed; skipping registration."
    exit 0
  fi

  ensure_jq
  require_cmd curl

  echo "OurCVEs: gathering host facts..."
  OS_NAME=$( . /etc/os-release && echo "$NAME" )
  OS_VERSION=$( . /etc/os-release && echo "$VERSION_ID" )
  KERNEL_VERSION=$(uname -r)
  HOSTNAME_FULL=$(timeout 5 hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")

  echo "OurCVEs: detecting display name..."
  DISPLAY_NAME=$(detect_display_name)

  echo "OurCVEs: registering \"$DISPLAY_NAME\" with $API_BASE..."

  RESPONSE=$(curl -sf --connect-timeout 5 --max-time 30 \
    -X POST "$API_BASE/servers/register" \
    -H "Authorization: Bearer $INSTALL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
          --arg hostname       "$HOSTNAME_FULL" \
          --arg name           "$DISPLAY_NAME" \
          --arg os_name        "$OS_NAME" \
          --arg os_version     "$OS_VERSION" \
          --arg kernel_version "$KERNEL_VERSION" \
          '{hostname:$hostname,name:$name,os_name:$os_name,os_version:$os_version,kernel_version:$kernel_version}')") \
    || { echo "OurCVEs: registration request failed (timed out or non-2xx response)." >&2; exit 1; }

  AGENT_TOKEN=$(echo "$RESPONSE" | jq -r '.agent_token // empty')
  [[ -z "$AGENT_TOKEN" ]] && {
    echo "OurCVEs: registration response missing agent_token." >&2
    echo "$RESPONSE" >&2
    exit 1
  }

  mkdir -p /etc/ourcves
  umask 077
  cat > "$CONFIG_FILE" <<EOF
AGENT_TOKEN=$AGENT_TOKEN
EOF
  chmod 0600 "$CONFIG_FILE"

  echo "OurCVEs: installing agent at $AGENT_BIN..."
  install_self_to_bin
  echo "OurCVEs: wiring up triggers (cron / apt / dnf / systemd)..."
  install_cron_backstop
  install_apt_hook
  install_dnf_hook
  install_systemd_boot_hook

  echo "OurCVEs: sending first report..."

  # Fall through to report mode using the token we just saved.
  AGENT_TOKEN=$AGENT_TOKEN
fi

# ── Report mode ───────────────────────────────────────────────────────────

if [[ -z "${AGENT_TOKEN:-}" ]]; then
  echo "OurCVEs: not installed. Run with --token <ouc_inst_...> first." >&2
  exit 1
fi

ensure_jq
require_cmd curl

KERNEL_VERSION=$(uname -r)
PACKAGES=$(collect_packages)
REBOOT_REQUIRED=$(detect_reboot_required)
REBOOT_PACKAGES=$(collect_reboot_packages)
HYGIENE=$(collect_hygiene)
PATCH_POSTURE=$(collect_patch_posture)
REPO_INVENTORY='{"repos":[],"truncated":false}'
case "$TRIGGER" in
  cron|manual|boot) REPO_INVENTORY=$(collect_repo_inventory) ;;
esac
AGENT_INFO=$(jq -nc --arg v "$AGENT_VERSION" '{version:$v, capabilities:["self_update","patch_posture","repo_discovery","lockfile_content"]}')

INGEST_BODY=$(jq -n \
  --arg     trigger                  "$TRIGGER" \
  --argjson reboot_required          "$REBOOT_REQUIRED" \
  --argjson reboot_required_packages "$REBOOT_PACKAGES" \
  --arg     kernel_version           "$KERNEL_VERSION" \
  --argjson packages                 "$PACKAGES" \
  --argjson hygiene                  "$HYGIENE" \
  --argjson patch_posture            "$PATCH_POSTURE" \
  --argjson agent                    "$AGENT_INFO" \
  '{trigger:$trigger,
    reboot_required:$reboot_required,
    reboot_required_packages:$reboot_required_packages,
    kernel_version:$kernel_version,
    packages:$packages,
    hygiene:$hygiene,
    patch_posture:$patch_posture,
    agent:$agent}')

case "$TRIGGER" in
  cron|manual|boot)
    INGEST_BODY=$(jq -c \
      --argjson discovered_repos "$(jq -c '.repos // []' <<<"$REPO_INVENTORY" 2>/dev/null || echo '[]')" \
      --argjson repos_truncated "$(jq -c '.truncated // false' <<<"$REPO_INVENTORY" 2>/dev/null || echo 'false')" \
      '. + {discovered_repos:$discovered_repos, repos_truncated:$repos_truncated}' \
      <<<"$INGEST_BODY")
    ;;
esac

HTTP_STATUS=$(curl -s --connect-timeout 5 --max-time 60 \
  -o /tmp/ourcves_response.json -w "%{http_code}" \
  -X POST "$API_BASE/servers/ingest" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$INGEST_BODY")

if [[ "$HTTP_STATUS" != "201" && "$HTTP_STATUS" != "202" ]]; then
  echo "OurCVEs agent: unexpected response $HTTP_STATUS" >&2
  cat /tmp/ourcves_response.json >&2 || true
  exit 1
fi

echo "OurCVEs agent: report accepted ($HTTP_STATUS, trigger=$TRIGGER)."

# Upload any requested lockfile content after the descriptor-only ingest succeeds.
upload_needed_lockfiles || true

# Apply a published, signed update if a newer signed version exists. Never fatal.
attempt_self_update "$TRIGGER" || true
