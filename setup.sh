#!/usr/bin/env bash
# NexGen Coding Competition 2026 - Linux setup.
#
# Scope: C toolchain (gcc, make), Python 3 + pip, and the Python libraries
# needed by the rounds. Nothing else is installed.
#
# It checks what is present, installs only what is missing (distro packages
# first, pip --user fallback), then runs verify.py. Safe to run twice.
#
# Usage:
#   bash setup.sh [--cache DIR] [--report FILE] [--offline] [--no-sudo]
#
# Writes setup-report.txt next to this script (unless --report is given).
# Exit: 0 = all required checks passed, 1 = manual attention needed.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${SCRIPT_DIR}/cache" ]; then
  CACHE_DIR="${SCRIPT_DIR}/cache"
elif [ -d "${SCRIPT_DIR}/../cache" ]; then
  CACHE_DIR="${SCRIPT_DIR}/../cache"
else
  CACHE_DIR="${SCRIPT_DIR}/cache"
fi
REPORT="${SCRIPT_DIR}/setup-report.txt"
OFFLINE=0
ALLOW_SUDO=1
PM="none"
PY_BIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cache) CACHE_DIR="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --no-sudo) ALLOW_SUDO=0; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$(dirname -- "$REPORT")"
: > "$REPORT"

log() {
  printf '%s\n' "$*" | tee -a "$REPORT"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

detect_pm() {
  local osr id like
  osr=/etc/os-release
  [ -r "$osr" ] || osr=/usr/lib/os-release
  id=""
  like=""
  if [ -r "$osr" ]; then
    # shellcheck disable=SC1090
    . "$osr"
    id="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
    like="$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
  fi
  case " $id $like " in
    *" ubuntu "*|*" debian "*|*" linuxmint "*|*" pop "*|*" elementary "*|*" zorin "*) printf 'apt'; return ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) printf 'dnf'; return ;;
    *" arch "*|*" manjaro "*|*" endeavouros "*|*" garuda "*) printf 'pacman'; return ;;
  esac
  local c
  for c in apt-get dnf yum pacman; do
    if have "$c"; then
      printf '%s' "$c"
      return
    fi
  done
  printf 'none'
}

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if [ "$ALLOW_SUDO" -eq 1 ] && have sudo; then
    SUDO="sudo"
  fi
fi

pm_install() {
  local pm="$1"
  shift
  [ "$pm" = "none" ] && return 1
  [ "$#" -eq 0 ] && return 0
  local attempt rc
  for attempt in 1 2 3; do
    rc=1
    case "$pm" in
      apt)
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get \
          -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
          -o DPkg::Lock::Timeout=300 update -qq || true
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get -y --no-install-recommends \
          -o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" \
          install "$@"
        rc=$?
        ;;
      dnf)
        $SUDO dnf -y --setopt=install_weak_deps=False --setopt=retries=10 \
          --setopt=timeout=60 install "$@"
        rc=$?
        ;;
      yum)
        $SUDO yum -y install "$@"
        rc=$?
        ;;
      pacman)
        $SUDO pacman -S --needed --noconfirm --disable-download-timeout "$@"
        rc=$?
        ;;
      *)
        return 1
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    log "WARN: package install attempt $attempt failed (exit $rc)"
    sleep $((attempt * 10))
  done
  return 1
}

find_python() {
  local c
  for c in python3 python; do
    if have "$c" && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}

pep668_flag() {
  if [ -n "$PY_BIN" ] && "$PY_BIN" -c 'import os, sysconfig; raise SystemExit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")) else 1)' >/dev/null 2>&1; then
    printf '%s' '--break-system-packages'
  fi
}

missing_libs() {
  "$PY_BIN" - <<'PY' 2>/dev/null
import importlib.util
mods = [
    ("PIL", "Pillow"),
    ("pygame", "pygame"),
    ("pandas", "pandas"),
    ("matplotlib", "matplotlib"),
    ("requests", "requests"),
    ("bs4", "beautifulsoup4"),
]
for module, package in mods:
    if importlib.util.find_spec(module) is None:
        print(package)
PY
}

pip_install_libs() {
  local packages="$1"
  local args=(install --user --disable-pip-version-check --no-warn-script-location --retries 10 --timeout 60)
  local flag attempt
  flag="$(pep668_flag)"
  [ -n "$flag" ] && args+=("$flag")
  [ -d "$CACHE_DIR/wheels" ] && args+=(--find-links "$CACHE_DIR/wheels")
  [ "$OFFLINE" -eq 1 ] && args+=(--no-index)
  for attempt in 1 2 3; do
    # shellcheck disable=SC2086
    if "$PY_BIN" -m pip "${args[@]}" $packages; then
      return 0
    fi
    log "WARN: pip install attempt $attempt failed"
    if [ "$attempt" -eq 1 ] && [ "$OFFLINE" -eq 0 ]; then
      "$PY_BIN" -m pip install --user --upgrade pip >/dev/null 2>&1 || true
    fi
    sleep $((attempt * 5))
  done
  return 1
}

log "NexGen setup report"
log "Date: $(date -Is)"
log "Host: $(uname -srm)"
log ""

PM="$(detect_pm)"
log "Package manager: $PM"
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
  log "WARN: not root and sudo is unavailable; only user-level installs are possible"
fi

case "$PM" in
  apt)
    BASE_PKGS="gcc make libc6-dev python3 python3-pip"
    PY_PKGS="python3-pil python3-pygame python3-pandas python3-matplotlib python3-requests python3-bs4"
    ;;
  dnf)
    BASE_PKGS="gcc make glibc-devel python3 python3-pip"
    PY_PKGS="python3-pillow python3-pygame python3-pandas python3-matplotlib python3-requests python3-beautifulsoup4 dejavu-sans-fonts"
    ;;
  yum)
    BASE_PKGS="gcc make glibc-devel python3 python3-pip"
    PY_PKGS="python3-pillow python3-pygame python3-pandas python3-matplotlib python3-requests python3-beautifulsoup4"
    ;;
  pacman)
    BASE_PKGS="gcc make python python-pip"
    PY_PKGS="python-pillow python-pygame python-pandas python-matplotlib python-requests python-beautifulsoup4"
    ;;
  *)
    BASE_PKGS=""
    PY_PKGS=""
    log "WARN: unsupported distribution; will only report what is present"
    ;;
esac

log ""
log "== Base tools =="
PY_BIN="$(find_python || true)"

MISSING_BASE=""
have gcc || MISSING_BASE="$MISSING_BASE gcc"
have make || MISSING_BASE="$MISSING_BASE make"
[ -n "$PY_BIN" ] || MISSING_BASE="$MISSING_BASE python3"

PIP_OK=0
if [ -n "$PY_BIN" ] && "$PY_BIN" -m pip --version >/dev/null 2>&1; then
  PIP_OK=1
else
  MISSING_BASE="$MISSING_BASE pip"
fi

if [ -n "${MISSING_BASE// /}" ]; then
  log "Missing:$MISSING_BASE -> installing distro packages"
  pm_install "$PM" $BASE_PKGS || log "WARN: base package install did not complete cleanly"
  PY_BIN="$(find_python || true)"
  have gcc && log "gcc: present" || log "FAIL: gcc is still missing"
  have make && log "make: present" || log "FAIL: make is still missing"
else
  log "gcc, make and Python 3 already present"
fi

if [ -n "$PY_BIN" ] && ! "$PY_BIN" -m pip --version >/dev/null 2>&1; then
  log "pip missing -> attempting ensurepip"
  "$PY_BIN" -m ensurepip --user >/dev/null 2>&1 || true
  if ! "$PY_BIN" -m pip --version >/dev/null 2>&1 && [ "$OFFLINE" -eq 0 ]; then
    GETPIP="$CACHE_DIR/get-pip.py"
    if [ ! -f "$GETPIP" ] && have curl; then
      curl -fsSL --retry 3 -o "$GETPIP" https://bootstrap.pypa.io/get-pip.py >/dev/null 2>&1 || true
    fi
    if [ -f "$GETPIP" ]; then
      "$PY_BIN" "$GETPIP" --user "$(pep668_flag)" >/dev/null 2>&1 || true
    fi
  fi
fi

log ""
log "== Python libraries =="
if [ -n "$PY_BIN" ]; then
  MISSING_LIBS="$(missing_libs | tr '\n' ' ')"
  if [ -n "${MISSING_LIBS// /}" ]; then
    log "Missing:$MISSING_LIBS -> trying distro packages"
    pm_install "$PM" $PY_PKGS || log "WARN: distro library install did not complete cleanly"
    MISSING_LIBS="$(missing_libs | tr '\n' ' ')"
  fi
  if [ -n "${MISSING_LIBS// /}" ]; then
    log "Still missing:$MISSING_LIBS -> pip --user fallback"
    pip_install_libs "$MISSING_LIBS" || log "WARN: pip fallback did not complete cleanly"
  fi
  if [ -z "$(missing_libs)" ]; then
    log "All Python libraries present"
  fi
else
  log "FAIL: no Python 3 interpreter available"
fi

if [ -n "$PY_BIN" ]; then
  log ""
  log "== Prepare caches =="
  MPLCONFIGDIR="${XDG_CACHE_HOME:-$HOME/.cache}/nexgen-matplotlib" MPLBACKEND=Agg \
    "$PY_BIN" -W ignore -c 'import matplotlib.pyplot' >/dev/null 2>&1 \
    && log "matplotlib font cache primed" || log "WARN: could not prime matplotlib cache"
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy PYGAME_HIDE_SUPPORT_PROMPT=1 \
    "$PY_BIN" -c 'import pygame' >/dev/null 2>&1 \
    && log "pygame import check" || log "WARN: pygame import check failed"
fi

log ""
log "== Verification =="
VERIFY_RC=1
if [ -n "$PY_BIN" ] && [ -f "$SCRIPT_DIR/verify.py" ]; then
  "$PY_BIN" "$SCRIPT_DIR/verify.py" "$REPORT"
  VERIFY_RC=$?
else
  RC=0
  have gcc || { log "FAIL: gcc not available"; RC=1; }
  have make || { log "FAIL: make not available"; RC=1; }
  [ -n "$PY_BIN" ] || { log "FAIL: python3 not available"; RC=1; }
  if [ -n "$PY_BIN" ] && [ -n "$(missing_libs)" ]; then
    log "FAIL: some libraries are still missing"
    RC=1
  fi
  VERIFY_RC=$RC
fi

log ""
if [ "$VERIFY_RC" -eq 0 ]; then
  log "Result: setup OK"
else
  log "Result: setup incomplete - check the FAIL lines above"
fi
exit "$VERIFY_RC"
