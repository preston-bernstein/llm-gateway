# shellcheck shell=bash
# Shared structured-logging helpers (home-infra CONVENTIONS.md §18 Shell
# house style). Source this from a script that has already set SERVICE_NAME
# and `set -euo pipefail` — it defines log/info/die and installs the ERR trap.
#
# Extracted from install.sh + update.sh (2026-08-15 polish pass): both
# scripts carried an identical log()/info()/die()/trap block except for the
# hardcoded "service" field, which is now the SERVICE_NAME the caller sets
# before sourcing this file.

log()   { printf '{"schema_version":1,"ts":"%s","level":"%s","service":"%s","event":"%s","msg":"%s"}\n' \
              "$(date -u +%FT%TZ)" "$1" "$SERVICE_NAME" "$2" "${3//\"/\\\"}"; }
info()  { log info "$1" "$2"; }
die()   { log critical "$1" "$2" >&2; exit 1; }
trap 'log critical script.failed "unexpected failure at line $LINENO: $BASH_COMMAND"' ERR
