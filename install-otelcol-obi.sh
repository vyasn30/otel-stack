#!/bin/bash
#
# install-otelcol-obi.sh — install the latest OpenTelemetry Collector (.deb)
# and point an existing OBI agent at it.
#
# Works on a bare machine: installs the collector (.deb) and, if OBI is absent,
# installs the OBI binary, a default config and a systemd unit. Existing installs
# are upgraded/retargeted rather than clobbered.
#
# Debian/Ubuntu only. It does NOT configure collector pipelines or any backend —
# edit /etc/otelcol/config.yaml for that.
#
# Env overrides:
#   OTELCOL_VERSION   pin a version (e.g. v0.160.0); default: latest release
#   OBI_VERSION       pin a version (e.g. v0.12.2);  default: latest release
#   OTLP_ENDPOINT     where OBI should send data; default: http://localhost:4318
#   OBI_CONFIG        default: /etc/obi-agent/config.yaml
#   SKIP_OBI=true     install/configure the collector only
#   WRITE_COLLECTOR_CONFIG=true
#                     install collector/config.yaml from this repo over
#                     /etc/otelcol/config.yaml (the existing one is backed up)
#   COLLECTOR_CONFIG_SRC
#                     override the source path for the above

set -o pipefail

# ─── Logging helpers ──────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

die() { log_error "$*"; exit 1; }

# ─── Preflight ────────────────────────────────────────────────────────────────

command_exists() { command -v "$1" >/dev/null 2>&1; }

required_commands=(curl awk sed grep dpkg systemctl install mktemp uname tar)
missing=()
for cmd in "${required_commands[@]}"; do
  command_exists "$cmd" || missing+=("$cmd")
done
[ ${#missing[@]} -eq 0 ] || die "Missing required commands: ${missing[*]}"

# Run privileged steps via sudo only when not already root.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command_exists sudo || die "Not root and sudo is not installed."
  SUDO="sudo"
fi

[ "$(uname -s)" = "Linux" ] || die "This script only runs on Linux."

if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID}:${ID_LIKE}" in
    debian*|ubuntu*|*:*debian*|*:*ubuntu*) log_ok "OS detected: ${ID}" ;;
    *) die "Not a Debian-based distribution (found '${ID}'). This script is .deb only." ;;
  esac
else
  die "/etc/os-release not found; cannot verify the distribution."
fi

ARCH_RAW=$(dpkg --print-architecture)
case "$ARCH_RAW" in
  amd64) ARCH=amd64 ;;
  arm64) ARCH=arm64 ;;
  *) die "Unsupported architecture '${ARCH_RAW}'. The collector ships amd64 and arm64 debs only." ;;
esac
log_info "Architecture: ${ARCH}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COLLECTOR_CONFIG_SRC="${COLLECTOR_CONFIG_SRC:-${SCRIPT_DIR}/collector/config.yaml}"

OTLP_ENDPOINT="${OTLP_ENDPOINT:-http://localhost:4318}"
OBI_CONFIG="${OBI_CONFIG:-/etc/obi-agent/config.yaml}"
OTELCOL_CONFIG=/etc/otelcol/config.yaml
REPO="open-telemetry/opentelemetry-collector-releases"
FALLBACK_VERSION="v0.160.0"
OBI_REPO="open-telemetry/opentelemetry-ebpf-instrumentation"
OBI_FALLBACK_VERSION="v0.12.2"
OBI_BINARY=/usr/local/bin/obi
OBI_UNIT=/etc/systemd/system/obi-agent.service

# ─── Resolve version ──────────────────────────────────────────────────────────

# Reads the newest stable tag for a repo; empty when the API is unreachable.
get_latest_tag() {
  curl -sSL --max-time 20 "https://api.github.com/repos/$1/releases/latest" \
    | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

if [ -z "${OTELCOL_VERSION}" ]; then
  OTELCOL_VERSION=$(get_latest_tag "${REPO}")
  if [ -z "${OTELCOL_VERSION}" ] || [ "${OTELCOL_VERSION}" = "null" ]; then
    log_warn "Could not reach the GitHub API; falling back to ${FALLBACK_VERSION}."
    OTELCOL_VERSION="${FALLBACK_VERSION}"
  fi
fi
# Release tags carry a leading 'v'; asset filenames do not.
VERSION_STRIPPED="${OTELCOL_VERSION#v}"
log_info "Target collector version: ${OTELCOL_VERSION}"

INSTALLED=$(dpkg-query -W -f='${Version}' otelcol 2>/dev/null || true)
if [ "${INSTALLED}" = "${VERSION_STRIPPED}" ]; then
  log_ok "otelcol ${INSTALLED} is already installed; skipping download."
  SKIP_INSTALL=true
else
  [ -n "${INSTALLED}" ] && log_info "Upgrading otelcol ${INSTALLED} -> ${VERSION_STRIPPED}"
  SKIP_INSTALL=false
fi

# ─── Install the collector ────────────────────────────────────────────────────

if [ "${SKIP_INSTALL}" != true ]; then
  DEB="otelcol_${VERSION_STRIPPED}_linux_${ARCH}.deb"
  URL="https://github.com/${REPO}/releases/download/${OTELCOL_VERSION}/${DEB}"
  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP}"' EXIT

  log_info "Downloading ${URL}"
  curl -fSL --max-time 180 -o "${TMP}/${DEB}" "${URL}" \
    || die "Download failed. Check that ${OTELCOL_VERSION} exists and ships a ${ARCH} .deb."
  log_ok "Downloaded ${DEB}"

  # Back up an existing config: this machine's collector config is hand-written,
  # and a package upgrade must never silently discard it.
  if [ -f "${OTELCOL_CONFIG}" ]; then
    BACKUP="${OTELCOL_CONFIG}.bak.$(date +%s)"
    $SUDO cp -a "${OTELCOL_CONFIG}" "${BACKUP}"
    log_ok "Backed up existing config -> ${BACKUP}"
  fi

  log_info "Installing ${DEB}"
  # --force-confold keeps the on-disk config when the package ships a new one.
  $SUDO dpkg --force-confold -i "${TMP}/${DEB}" || die "dpkg install failed."
  log_ok "otelcol ${VERSION_STRIPPED} installed"
fi

# ── Optional: install this repo's collector config ───────────────────────────
if [ "${WRITE_COLLECTOR_CONFIG}" = true ]; then
  [ -f "${COLLECTOR_CONFIG_SRC}" ] \
    || die "WRITE_COLLECTOR_CONFIG=true but no config at ${COLLECTOR_CONFIG_SRC}"

  # Validate before installing: a bad config makes the collector exit on start,
  # and it is far clearer to fail here than to debug a dead unit afterwards.
  if ! $SUDO otelcol validate --config="file:${COLLECTOR_CONFIG_SRC}" >/dev/null 2>&1; then
    log_error "Config at ${COLLECTOR_CONFIG_SRC} failed validation:"
    $SUDO otelcol validate --config="file:${COLLECTOR_CONFIG_SRC}" 2>&1 | sed 's/^/        /'
    die "Refusing to install an invalid collector config."
  fi

  if [ -f "${OTELCOL_CONFIG}" ]; then
    CFG_BACKUP="${OTELCOL_CONFIG}.bak.$(date +%s)"
    $SUDO cp -a "${OTELCOL_CONFIG}" "${CFG_BACKUP}"
    log_ok "Backed up collector config -> ${CFG_BACKUP}"
  fi
  $SUDO install -m 0644 "${COLLECTOR_CONFIG_SRC}" "${OTELCOL_CONFIG}"
  log_ok "Installed ${COLLECTOR_CONFIG_SRC} -> ${OTELCOL_CONFIG}"
else
  log_info "Leaving ${OTELCOL_CONFIG} as-is (set WRITE_COLLECTOR_CONFIG=true to install this repo's config)."
fi

$SUDO systemctl daemon-reload
$SUDO systemctl enable otelcol >/dev/null 2>&1 || true
$SUDO systemctl restart otelcol || die "otelcol failed to start. Check: journalctl -u otelcol -n 30"

# A bad config makes the collector exit immediately, so confirm it stayed up.
sleep 2
systemctl is-active --quiet otelcol \
  || die "otelcol is not active. A config error is most likely: journalctl -u otelcol -n 30"
log_ok "otelcol is active"

# ─── Point OBI at the collector ───────────────────────────────────────────────

if [ "${SKIP_OBI}" = true ]; then
  log_info "SKIP_OBI=true — leaving the OBI agent untouched."
  exit 0
fi

# 4317 is gRPC, 4318 is HTTP. Derive protocol from the port so a mismatch —
# which fails silently, with no spans and no error — cannot happen.
case "${OTLP_ENDPOINT}" in
  *:4317*) OTLP_PROTOCOL="grpc" ;;
  *)       OTLP_PROTOCOL="http/protobuf" ;;
esac

OBI_UNIT_EXISTED=true
if ! systemctl list-unit-files 2>/dev/null | grep -q '^obi-agent\.service'; then
  OBI_UNIT_EXISTED=false
  log_info "obi-agent.service not found — installing OBI from scratch."
fi

# ── Install the OBI binary if absent ─────────────────────────────────────────
if [ ! -x "${OBI_BINARY}" ]; then
  if [ -z "${OBI_VERSION}" ]; then
    OBI_VERSION=$(get_latest_tag "${OBI_REPO}")
    if [ -z "${OBI_VERSION}" ] || [ "${OBI_VERSION}" = "null" ]; then
      log_warn "Could not reach the GitHub API; falling back to OBI ${OBI_FALLBACK_VERSION}."
      OBI_VERSION="${OBI_FALLBACK_VERSION}"
    fi
  fi

  OBI_TARBALL="obi-${OBI_VERSION}-linux-${ARCH}.tar.gz"
  OBI_URL="https://github.com/${OBI_REPO}/releases/download/${OBI_VERSION}/${OBI_TARBALL}"
  OBI_TMP=$(mktemp -d)

  log_info "Downloading ${OBI_URL}"
  curl -fSL --max-time 300 -o "${OBI_TMP}/${OBI_TARBALL}" "${OBI_URL}" \
    || { rm -rf "${OBI_TMP}"; die "Failed to download OBI ${OBI_VERSION}."; }

  # Verify against the release SHA256SUMS. This binary runs as root and loads
  # eBPF programs into the kernel, so a corrupted or tampered download matters.
  if curl -fsSL --max-time 60 -o "${OBI_TMP}/SHA256SUMS" \
       "https://github.com/${OBI_REPO}/releases/download/${OBI_VERSION}/SHA256SUMS"; then
    if command_exists sha256sum && \
       ( cd "${OBI_TMP}" && sha256sum -c SHA256SUMS --ignore-missing --status ); then
      log_ok "SHA256 checksum verified"
    else
      rm -rf "${OBI_TMP}"
      die "SHA256 checksum verification FAILED for ${OBI_TARBALL}."
    fi
  else
    log_warn "SHA256SUMS not available for ${OBI_VERSION}; skipping checksum verification."
  fi

  # The archive is flat: the `obi` binary sits at the root next to licence files.
  tar -xzf "${OBI_TMP}/${OBI_TARBALL}" -C "${OBI_TMP}" obi \
    || { rm -rf "${OBI_TMP}"; die "Could not extract 'obi' from ${OBI_TARBALL}."; }

  $SUDO install -m 0755 "${OBI_TMP}/obi" "${OBI_BINARY}" \
    || { rm -rf "${OBI_TMP}"; die "Failed to install ${OBI_BINARY}."; }
  rm -rf "${OBI_TMP}"
  log_ok "Installed OBI ${OBI_VERSION} -> ${OBI_BINARY}"
else
  log_info "OBI binary already present at ${OBI_BINARY}; leaving it alone."
fi

# ── Write a default OBI config if absent ─────────────────────────────────────
if [ ! -f "${OBI_CONFIG}" ]; then
  $SUDO mkdir -p "$(dirname "${OBI_CONFIG}")"
  $SUDO tee "${OBI_CONFIG}" >/dev/null <<OBICFG
# OBI agent configuration — written by install-otelcol-obi.sh
log_level: INFO

ebpf:
  context_propagation: all

# Both signals go to the same collector endpoint: OTLP carries the signal type
# in the request path (/v1/traces, /v1/metrics), so one address serves both.
otel_traces_export:
  endpoint: ${OTLP_ENDPOINT}
  protocol: ${OTLP_PROTOCOL}

otel_metrics_export:
  endpoint: ${OTLP_ENDPOINT}
  protocol: ${OTLP_PROTOCOL}

metrics:
  features:
    - application
    - application_span

# With no 'discovery' section OBI auto-instruments every eligible process and
# derives service names from executables. Add selectors to control naming:
#
# discovery:
#   instrument:
#     - name: my-app
#       open_ports: "8080"
#       languages: go
OBICFG
  $SUDO chmod 0640 "${OBI_CONFIG}"
  log_ok "Wrote default config -> ${OBI_CONFIG}"
fi

log_info "Pointing OBI at ${OTLP_ENDPOINT} (${OTLP_PROTOCOL})"

OBI_BACKUP="${OBI_CONFIG}.bak.$(date +%s)"
# (Freshly written configs already carry the right endpoint, but rewriting is
#  idempotent, so this path is safe either way.)
$SUDO cp -a "${OBI_CONFIG}" "${OBI_BACKUP}"
log_ok "Backed up OBI config -> ${OBI_BACKUP}"

# Rewrite endpoint/protocol inside the two export blocks only, line by line, so
# comments and every unrelated section (discovery selectors especially) survive.
TMP_YAML=$(mktemp)
$SUDO awk -v ep="${OTLP_ENDPOINT}" -v proto="${OTLP_PROTOCOL}" '
  /^[A-Za-z_][A-Za-z0-9_]*:/ { blk = $0; sub(/:.*/, "", blk) }
  {
    if (blk == "otel_traces_export" || blk == "otel_metrics_export") {
      if ($0 ~ /^[[:space:]]+endpoint:/) {
        match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "endpoint: " ep; next
      }
      if ($0 ~ /^[[:space:]]+protocol:/) {
        match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "protocol: " proto; next
      }
    }
    print
  }
' "${OBI_CONFIG}" > "${TMP_YAML}" || die "Failed to rewrite ${OBI_CONFIG}"

if [ ! -s "${TMP_YAML}" ]; then
  rm -f "${TMP_YAML}"
  die "Rewrite produced an empty file; ${OBI_CONFIG} left untouched."
fi
$SUDO install -m 0644 "${TMP_YAML}" "${OBI_CONFIG}"
rm -f "${TMP_YAML}"

if $SUDO grep -q "endpoint: ${OTLP_ENDPOINT}" "${OBI_CONFIG}"; then
  log_ok "OBI export endpoints rewritten"
else
  log_warn "No endpoint lines were changed — check that ${OBI_CONFIG} has"
  log_warn "otel_traces_export / otel_metrics_export blocks with an 'endpoint:' key."
fi

# ── systemd unit ─────────────────────────────────────────────────────────────
if [ "${OBI_UNIT_EXISTED}" != true ]; then
  # ProtectHome=true blocks OBI from reading processes under /home; flip it to
  # false if you need to instrument apps running out of a home directory.
  $SUDO tee "${OBI_UNIT}" >/dev/null <<UNIT
[Unit]
Description=OpenTelemetry eBPF Instrumentation (OBI) Agent
Documentation=https://opentelemetry.io/docs/zero-code/obi/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${OBI_BINARY} --config=${OBI_CONFIG}
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
LimitNOFILE=65536
LimitMEMLOCK=infinity
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  log_ok "Wrote ${OBI_UNIT}"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable obi-agent >/dev/null 2>&1 || true
else
  # A pre-existing unit (e.g. from a vendor installer) may carry its own
  # OTEL_EXPORTER_OTLP_ENDPOINT, which takes precedence over the config file and
  # would silently override the endpoint written above. Clear it with a drop-in
  # rather than editing the unit, which an installer re-run would overwrite.
  if systemctl show obi-agent -p Environment --value 2>/dev/null | grep -q 'OTEL_EXPORTER_OTLP_ENDPOINT'; then
    DROPIN_DIR=/etc/systemd/system/obi-agent.service.d
    $SUDO mkdir -p "${DROPIN_DIR}"
    printf '%s\n' \
      '# Managed by install-otelcol-obi.sh' \
      '# The empty Environment= resets values inherited from the unit so that' \
      '# the endpoint in the OBI config file stays the single source of truth.' \
      '[Service]' \
      'Environment=' \
      | $SUDO tee "${DROPIN_DIR}/10-clear-otlp-endpoint.conf" >/dev/null
    log_ok "Cleared the unit's OTLP endpoint override via ${DROPIN_DIR}/10-clear-otlp-endpoint.conf"
  fi
fi

$SUDO systemctl daemon-reload
$SUDO systemctl restart obi-agent || die "obi-agent failed to restart. Check: journalctl -u obi-agent -n 30"
sleep 2
systemctl is-active --quiet obi-agent \
  || die "obi-agent is not active. Check: journalctl -u obi-agent -n 30"
log_ok "obi-agent is active"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "================================================================="
echo "  OpenTelemetry Collector ${VERSION_STRIPPED} (${ARCH}) ready"
echo "================================================================="
echo ""
echo "  Collector config:  ${OTELCOL_CONFIG}"
echo "  OBI config:        ${OBI_CONFIG}"
echo "  OBI exports to:    ${OTLP_ENDPOINT} (${OTLP_PROTOCOL})"
echo ""
echo "  Verify:"
echo "    systemctl status otelcol obi-agent"
echo "    ss -ltn | grep -E ':4317|:4318'"
echo "    curl -s localhost:8889/metrics | grep otelcol_receiver_accepted_spans"
echo ""
echo "  Note: this script does not configure collector pipelines."
echo "  Edit ${OTELCOL_CONFIG} to add exporters, then: systemctl restart otelcol"
echo ""
