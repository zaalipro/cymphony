#!/usr/bin/env bash
# Ship a Linux Cymphony binary to ssh Host gcp (zaali@34.136.10.30) and
# restart whatever already supervises it.
#
#   ./scripts/deploy-gcp.sh              # make all, build linux burrito, deploy
#   ./scripts/deploy-gcp.sh --inspect    # print supervisor / binary / upstream
#   ./scripts/deploy-gcp.sh --skip-make-all
#   ./scripts/deploy-gcp.sh --skip-build # reuse burrito_out/cymphony_linux
#
# Discovers systemd unit `cymphony` vs ~/.cymphony/cymphony.pid, the running
# binary (/usr/bin, /opt, $HOME, PATH), and the nginx proxy_pass port for
# https://cymphony.llmotions.com/. Replaces that binary only and restarts the
# existing supervisor. Health-checks 127.0.0.1:<upstream>.
#
# Does not: export LINEAR_API_KEY, run `cymphony add` / `cymphony setup`,
# write ~/.cymphony/config.json, print secrets, or create a new supervisor.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SSH_HOST="${CYMPHONY_DEPLOY_SSH_HOST:-gcp}"
DOMAIN="${CYMPHONY_DEPLOY_DOMAIN:-cymphony.llmotions.com}"
LINUX_TARGET_NAME="${CYMPHONY_BURRITO_TARGET:-linux}"
LOCAL_ARTIFACT="${CYMPHONY_LINUX_ARTIFACT:-${REPO_DIR}/burrito_out/cymphony_linux}"
HEALTH_PATH="${CYMPHONY_DEPLOY_HEALTH_PATH:-/}"
HEALTH_TRIES="${CYMPHONY_DEPLOY_HEALTH_TRIES:-30}"
HEALTH_SLEEP_S="${CYMPHONY_DEPLOY_HEALTH_SLEEP_S:-2}"

DO_INSPECT=0
DO_MAKE_ALL=1
DO_BUILD=1

usage() {
  cat <<EOF
Usage: $0 [--inspect] [--skip-make-all] [--skip-build] [--help]

  --inspect         Discover supervisor, binary, and nginx upstream; do not ship.
  --skip-make-all   Skip the local \`make all\` quality gate.
  --skip-build      Reuse ${LOCAL_ARTIFACT} instead of building.

SSH target defaults to Host ${SSH_HOST} (~/.ssh/config → zaali@34.136.10.30).
Overrides: CYMPHONY_DEPLOY_SSH_HOST, CYMPHONY_DEPLOY_DOMAIN,
CYMPHONY_LINUX_ARTIFACT, CYMPHONY_BURRITO_TARGET,
CYMPHONY_DEPLOY_HEALTH_TRIES, CYMPHONY_DEPLOY_HEALTH_SLEEP_S.

This script never exports LINEAR_API_KEY and never runs cymphony add/setup.
Connect Linear and add projects from the dashboard after deploy.
EOF
}

while (($# > 0)); do
  case "$1" in
    --inspect | --print-discovery) DO_INSPECT=1 ;;
    --skip-make-all | --skip-tests) DO_MAKE_ALL=0 ;;
    --skip-build) DO_BUILD=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

step() { printf '\n==> %s\n' "$*"; }

redact() {
  sed -E \
    -e 's/lin_[A-Za-z0-9]+/lin_REDACTED/g' \
    -e 's/(sk-|sk-ant-|sk-zai-)[A-Za-z0-9_-]+/\1REDACTED/g' \
    -e 's/(LINEAR_API_KEY|CYMPHONY_API_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY)=[^[:space:]]+/\1=REDACTED/g'
}

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=20
)

run_ssh() {
  ssh "${SSH_OPTS[@]}" "${SSH_HOST}" "$@"
}

# Remote discovery + install/restart. Printed lines are KEY=value (no secrets).
# stdin is ignored; the body is a self-contained bash script.
REMOTE_LIB=$(
  cat <<'REMOTE'
set -euo pipefail

DOMAIN="${CYMPHONY_DEPLOY_DOMAIN:-cymphony.llmotions.com}"

redact() {
  sed -E \
    -e 's/lin_[A-Za-z0-9]+/lin_REDACTED/g' \
    -e 's/(sk-|sk-ant-|sk-zai-)[A-Za-z0-9_-]+/\1REDACTED/g' \
    -e 's/(LINEAR_API_KEY|CYMPHONY_API_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY)=[^[:space:]]+/\1=REDACTED/g'
}

have_sudo() {
  sudo -n true >/dev/null 2>&1
}

maybe_sudo() {
  if have_sudo; then
    sudo -n "$@"
  else
    "$@"
  fi
}

unit_loaded() {
  systemctl show -p LoadState --value cymphony 2>/dev/null | grep -qx loaded
}

unit_active() {
  systemctl is-active --quiet cymphony 2>/dev/null
}

pidfile_path() {
  printf '%s\n' "${HOME}/.cymphony/cymphony.pid"
}

read_pid() {
  local path
  path="$(pidfile_path)"
  if [[ -f "${path}" ]]; then
    tr -d '[:space:]' <"${path}"
  fi
}

pid_alive() {
  local pid="${1:-}"
  [[ -n "${pid}" && -d "/proc/${pid}" ]]
}

nginx_upstream_port() {
  local dump=""
  if have_sudo; then
    dump="$(sudo -n nginx -T 2>/dev/null || true)"
  fi
  if [[ -z "${dump}" ]]; then
    dump="$(cat /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/conf.d/* 2>/dev/null || true)"
  fi
  printf '%s\n' "${dump}" | awk -v domain="${DOMAIN}" '
    $1 == "server_name" {
      in_server = 0
      for (i = 2; i <= NF; i++) {
        gsub(/;/, "", $i)
        if ($i == domain) in_server = 1
      }
      next
    }
    in_server && $1 == "proxy_pass" {
      if (match($0, /127\.0\.0\.1:[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*:/, "", s)
        print s
        exit
      }
      if (match($0, /localhost:[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*:/, "", s)
        print s
        exit
      }
    }
    in_server && $1 == "}" { in_server = 0 }
  '
}

listen_ports_for_pid() {
  local pid="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v pid="${pid}" '
      index($0, "pid=" pid ",") {
        n = split($0, parts, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (match(parts[i], /:[0-9]+$/)) {
            print substr(parts[i], RSTART + 1)
          }
        }
      }
    ' | sort -u
  fi
}

dashboard_url_port() {
  local url_file="${HOME}/.cymphony/dashboard.url"
  if [[ -f "${url_file}" ]]; then
    sed -nE 's#.*://[^/]+:([0-9]+).*#\1#p' "${url_file}" | head -n 1
  fi
}

execstart_bin() {
  local exec_start
  exec_start="$(systemctl show -p ExecStart --value cymphony 2>/dev/null || true)"
  # systemd encodes argv as { path=/usr/bin/cymphony ; argv[]=/usr/bin/cymphony port 4089 start ; ...
  if [[ "${exec_start}" =~ path=([^[:space:];]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${exec_start}" =~ argv\[\]=([^[:space:];]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

execstart_args() {
  local exec_start
  exec_start="$(systemctl show -p ExecStart --value cymphony 2>/dev/null || true)"
  if [[ "${exec_start}" =~ argv\[\]=([^;]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

cmdline_of() {
  local pid="$1"
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline"
    printf '\n'
  fi
}

exe_of() {
  local pid="$1"
  readlink -f "/proc/${pid}/exe" 2>/dev/null || true
}

looks_like_wrapper() {
  local path="$1"
  [[ -n "${path}" && -f "${path}" && -x "${path}" ]] || return 1
  local base
  base="$(basename "${path}")"
  case "${base}" in
    beam.smp | erl | erlexec | epmd) return 1 ;;
  esac
  # Burrito unpacks ERTS + BEAM under a cache/payload dir; never overwrite that.
  case "${path}" in
    */.cache/* | */.local/share/* | */burrito* | */erts-*/*) return 1 ;;
  esac
  return 0
}

discover_binary() {
  local candidate
  if unit_loaded; then
    candidate="$(execstart_bin || true)"
    if looks_like_wrapper "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi
  for candidate in \
    /usr/bin/cymphony \
    /usr/local/bin/cymphony \
    /opt/cymphony/cymphony \
    /opt/cymphony/bin/cymphony \
    "${HOME}/.local/bin/cymphony" \
    "${HOME}/bin/cymphony"; do
    if looks_like_wrapper "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  candidate="$(command -v cymphony 2>/dev/null || true)"
  if looks_like_wrapper "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  return 1
}

discover_supervisor() {
  if unit_loaded; then
    printf 'systemd\n'
    return 0
  fi
  if pid_alive "$(read_pid || true)"; then
    printf 'pidfile\n'
    return 0
  fi
  if [[ -f "$(pidfile_path)" ]]; then
    printf 'stale_pidfile\n'
    return 0
  fi
  printf 'none\n'
}

discover_port() {
  local port pid
  port="$(nginx_upstream_port || true)"
  if [[ "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${port}"
    return 0
  fi
  pid="$(read_pid || true)"
  if pid_alive "${pid}"; then
    port="$(listen_ports_for_pid "${pid}" | head -n 1 || true)"
    if [[ "${port}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${port}"
      return 0
    fi
  fi
  port="$(dashboard_url_port || true)"
  if [[ "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${port}"
    return 0
  fi
  return 1
}

print_discovery() {
  local supervisor binary port pid
  supervisor="$(discover_supervisor)"
  binary="$(discover_binary || true)"
  port="$(discover_port || true)"
  pid="$(read_pid || true)"

  printf 'supervisor=%s\n' "${supervisor}"
  printf 'binary=%s\n' "${binary:-}"
  printf 'upstream_port=%s\n' "${port:-}"
  printf 'pidfile=%s\n' "$(pidfile_path)"
  printf 'pid=%s\n' "${pid:-}"
  printf 'pid_alive=%s\n' "$(pid_alive "${pid:-}" && echo yes || echo no)"
  printf 'systemd_loaded=%s\n' "$(unit_loaded && echo yes || echo no)"
  printf 'systemd_active=%s\n' "$(unit_active && echo yes || echo no)"
  if unit_loaded; then
    printf 'systemd_fragment=%s\n' "$(systemctl show -p FragmentPath --value cymphony 2>/dev/null || true)"
    printf 'systemd_execstart=%s\n' "$(execstart_args | redact || true)"
  fi
  if pid_alive "${pid:-}"; then
    printf 'cmdline=%s\n' "$(cmdline_of "${pid}" | redact)"
    printf 'exe=%s\n' "$(exe_of "${pid}")"
  fi
  printf 'config_json=%s\n' "$([[ -f "${HOME}/.cymphony/config.json" ]] && echo present || echo missing)"
  printf 'which_cymphony=%s\n' "$(command -v cymphony 2>/dev/null || true)"
}

# Print preserved CLI tokens (one per line) from the live pid, minus the
# wrapper path and flags `cymphony start` will re-add.
preserved_start_tokens() {
  local pid="$1"
  local token
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  while IFS= read -r -d '' token; do
    case "${token}" in
      '' | --daemon-internal | --background | start) continue ;;
      -*)
        printf '%s\n' "${token}"
        ;;
      *)
        if [[ "${token}" == */cymphony || "${token}" == cymphony ]]; then
          continue
        fi
        printf '%s\n' "${token}"
        ;;
    esac
  done <"/proc/${pid}/cmdline"
}

install_binary() {
  local src="$1"
  local dest="$2"
  local dest_dir backup
  dest_dir="$(dirname "${dest}")"
  backup="${dest}.bak.$(date -u +%Y%m%d%H%M%S)"

  if [[ ! -f "${src}" ]]; then
    echo "Staged binary missing: ${src}" >&2
    exit 1
  fi
  chmod 0755 "${src}"

  if [[ -e "${dest}" ]]; then
    if [[ -w "${dest}" ]]; then
      cp -a "${dest}" "${backup}"
    else
      maybe_sudo cp -a "${dest}" "${backup}"
    fi
    echo "backup=${backup}"
  fi

  if [[ -w "${dest_dir}" ]] && { [[ ! -e "${dest}" ]] || [[ -w "${dest}" ]]; }; then
    cp -f "${src}" "${dest}"
    chmod 0755 "${dest}"
  else
    maybe_sudo install -m 0755 "${src}" "${dest}"
  fi
  echo "installed=${dest}"
}

restart_supervisor() {
  local supervisor binary
  supervisor="$(discover_supervisor)"
  binary="$(discover_binary)"

  case "${supervisor}" in
    systemd)
      if unit_active; then
        maybe_sudo systemctl restart cymphony
      else
        maybe_sudo systemctl start cymphony
      fi
      echo "restart=systemd"
      ;;
    pidfile | stale_pidfile)
      local -a extra=()
      local token pid
      pid="$(read_pid || true)"
      if pid_alive "${pid}"; then
        while IFS= read -r token; do
          extra+=("${token}")
        done < <(preserved_start_tokens "${pid}")
      fi
      if command -v cymphony >/dev/null 2>&1; then
        cymphony stop >/dev/null 2>&1 || true
      elif [[ -n "${binary}" ]]; then
        "${binary}" stop >/dev/null 2>&1 || true
      fi
      if [[ ! -f "${HOME}/.cymphony/config.json" ]]; then
        echo "Refusing to start: ~/.cymphony/config.json is missing (would invoke setup)." >&2
        exit 1
      fi
      # Recreate the previous argv (typically `port N`) then `start`. Never add/setup.
      "${binary}" "${extra[@]}" start
      echo "restart=pidfile"
      ;;
    *)
      echo "No existing supervisor (systemd unit cymphony or ~/.cymphony/cymphony.pid)." >&2
      exit 1
      ;;
  esac
}

healthcheck() {
  local port="$1"
  local path="${2:-/}"
  local tries="${3:-30}"
  local sleep_s="${4:-2}"
  local url code i
  url="http://127.0.0.1:${port}${path}"
  for i in $(seq 1 "${tries}"); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || true)"
    case "${code}" in
      200 | 202 | 204 | 301 | 302 | 303 | 307 | 308 | 401 | 403)
        echo "health_url=${url}"
        echo "health_status=${code}"
        echo "health=ok"
        return 0
        ;;
    esac
    sleep "${sleep_s}"
  done
  echo "health_url=${url}"
  echo "health_status=${code:-000}"
  echo "health=fail"
  return 1
}

cmd="${1:-discover}"
shift || true
case "${cmd}" in
  discover) print_discovery ;;
  install)
    install_binary "${1:?staged path}" "${2:?dest path}"
    ;;
  restart) restart_supervisor ;;
  health)
    healthcheck "${1:?port}" "${2:-/}" "${3:-30}" "${4:-2}"
    ;;
  *)
    echo "unknown remote command: ${cmd}" >&2
    exit 64
    ;;
esac
REMOTE
)

run_remote() {
  local cmd="$1"
  shift
  # Pass domain so nginx lookup matches the public vhost.
  printf '%s\n' "${REMOTE_LIB}" | run_ssh "CYMPHONY_DEPLOY_DOMAIN=$(printf '%q' "${DOMAIN}") bash -s -- ${cmd} $(printf '%q ' "$@")"
}

require_cmd ssh
require_cmd scp

step "SSH ${SSH_HOST} (${DOMAIN})"
if ! run_ssh "true"; then
  echo "Cannot ssh ${SSH_HOST}. Check Host gcp in ~/.ssh/config (zaali@34.136.10.30)." >&2
  exit 1
fi

step "Discover existing supervisor / binary / upstream"
DISCOVERY="$(run_remote discover | redact)"
printf '%s\n' "${DISCOVERY}"

SUPERVISOR="$(printf '%s\n' "${DISCOVERY}" | awk -F= '/^supervisor=/{print $2; exit}')"
BINARY="$(printf '%s\n' "${DISCOVERY}" | awk -F= '/^binary=/{print $2; exit}')"
UPSTREAM_PORT="$(printf '%s\n' "${DISCOVERY}" | awk -F= '/^upstream_port=/{print $2; exit}')"
CONFIG_JSON="$(printf '%s\n' "${DISCOVERY}" | awk -F= '/^config_json=/{print $2; exit}')"

if [[ "${DO_INSPECT}" == "1" ]]; then
  echo
  echo "Inspect only. Not shipping a binary."
  exit 0
fi

if [[ "${SUPERVISOR}" == "none" || "${SUPERVISOR}" == "stale_pidfile" ]]; then
  echo "No live supervisor on ${SSH_HOST} (need systemd unit cymphony or a live ~/.cymphony/cymphony.pid)." >&2
  echo "This script will not create a unit or run cymphony setup/add." >&2
  exit 1
fi

if [[ -z "${BINARY}" ]]; then
  echo "Could not locate the existing cymphony binary on ${SSH_HOST}." >&2
  exit 1
fi

if [[ ! "${UPSTREAM_PORT}" =~ ^[0-9]+$ ]]; then
  echo "Could not discover nginx upstream port for ${DOMAIN}." >&2
  exit 1
fi

if [[ "${CONFIG_JSON}" != "present" ]]; then
  echo "Refusing to deploy: ~/.cymphony/config.json is missing on the host (start would invoke setup)." >&2
  exit 1
fi

if [[ "${DO_MAKE_ALL}" == "1" ]]; then
  step "Local quality gate (make all)"
  require_cmd make
  (cd "${REPO_DIR}" && make all)
fi

if [[ "${DO_BUILD}" == "1" ]]; then
  step "Build Linux burrito (${LINUX_TARGET_NAME})"
  if ! command -v zig >/dev/null 2>&1; then
    echo "zig is required to cross-compile the Linux burrito binary (0.15.2)." >&2
    echo "Install Zig 0.15.2 and ensure it is on PATH." >&2
    exit 1
  fi
  (
    cd "${REPO_DIR}"
    if command -v mise >/dev/null 2>&1; then
      BURRITO_BUILD=1 MIX_ENV=prod BURRITO_TARGET="${LINUX_TARGET_NAME}" mise exec -- mix deps.get
      BURRITO_BUILD=1 MIX_ENV=prod BURRITO_TARGET="${LINUX_TARGET_NAME}" mise exec -- mix release --overwrite
    else
      BURRITO_BUILD=1 MIX_ENV=prod BURRITO_TARGET="${LINUX_TARGET_NAME}" mix deps.get
      BURRITO_BUILD=1 MIX_ENV=prod BURRITO_TARGET="${LINUX_TARGET_NAME}" mix release --overwrite
    fi
  )
fi

if [[ ! -f "${LOCAL_ARTIFACT}" ]]; then
  echo "Linux artifact missing: ${LOCAL_ARTIFACT}" >&2
  echo "Build with BURRITO_BUILD=1 MIX_ENV=prod BURRITO_TARGET=${LINUX_TARGET_NAME} mix release --overwrite" >&2
  exit 1
fi

if command -v file >/dev/null 2>&1; then
  ARTIFACT_KIND="$(file -b "${LOCAL_ARTIFACT}" || true)"
  printf 'artifact=%s\n' "${LOCAL_ARTIFACT}"
  printf 'artifact_kind=%s\n' "${ARTIFACT_KIND}"
  case "${ARTIFACT_KIND}" in
    *ELF*x86-64* | *ELF*x86_64* | *ELF*64-bit*LSB*) ;;
    *)
      echo "Refusing to ship a non-Linux-x86_64 artifact." >&2
      exit 1
      ;;
  esac
fi

STAGING="/tmp/cymphony_linux.$$"
step "Copy ${LOCAL_ARTIFACT} → ${SSH_HOST}:${STAGING}"
scp "${SSH_OPTS[@]}" "${LOCAL_ARTIFACT}" "${SSH_HOST}:${STAGING}"

cleanup_staging() {
  run_ssh "rm -f $(printf '%q' "${STAGING}")" >/dev/null 2>&1 || true
}
trap cleanup_staging EXIT

step "Install over ${BINARY}"
run_remote install "${STAGING}" "${BINARY}" | redact

step "Restart existing supervisor (${SUPERVISOR})"
run_remote restart | redact

step "Health-check http://127.0.0.1:${UPSTREAM_PORT}${HEALTH_PATH}"
if ! run_remote health "${UPSTREAM_PORT}" "${HEALTH_PATH}" "${HEALTH_TRIES}" "${HEALTH_SLEEP_S}"; then
  echo "Upstream health check failed." >&2
  if [[ "${SUPERVISOR}" == "systemd" ]]; then
    run_ssh "systemctl is-active cymphony || true" || true
    run_ssh "journalctl -u cymphony -n 40 --no-pager" 2>/dev/null | redact || true
  else
    run_ssh 'if test -f ~/.cymphony/cymphony.pid; then echo pidfile_present=yes; else echo pidfile_present=no; fi' || true
  fi
  exit 1
fi

step "Supervisor after deploy"
run_ssh 'if systemctl is-active cymphony >/dev/null 2>&1 || test -f ~/.cymphony/cymphony.pid; then echo supervisor_ok=yes; else echo supervisor_ok=no; fi'

echo
echo "Deployed ${LOCAL_ARTIFACT} to ${SSH_HOST}:${BINARY} (upstream ${UPSTREAM_PORT})."
echo "Public URL: https://${DOMAIN}/ (nginx basic auth in front; do not inject LINEAR_API_KEY here)."
echo "Smoke Linear connect + add-project from the dashboard, not via cymphony add/setup."
