#!/usr/bin/env bash
# common.sh — shared helpers for rxbroker. Sourced, not executed.
#
# Provides: config resolution, deterministic key/path derivation, the per-repo
# state layout, a minimal TOML reader, and an atomic JSON index.
# Requires: bash, jq, flock, sha256sum (all assumed present; checked by rxbroker).

# ---- constants -------------------------------------------------------------
RXB_TYPES="codegen review openspec"

# ---- small utilities -------------------------------------------------------
rxb_die() { printf 'rxbroker: %s\n' "$*" >&2; exit 1; }

rxb_is_type() {
  case " $RXB_TYPES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Skill root = two levels up from this file (scripts/lib/common.sh -> skill/).
rxb_skill_root() { ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd ); }

# ---- repo / state layout ---------------------------------------------------
# repo_id: git toplevel if available, else the absolute directory. This is the
# stable identity that scopes a session key to a project.
rxb_repo_id() {
  local dir="${1:-$PWD}"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || ( cd "$dir" && pwd )
}

rxb_state_dir()    { printf '%s/.reasonix-broker\n' "$1"; }            # $1 = repo_id
rxb_sessions_dir() { printf '%s/sessions\n' "$1"; }                    # $1 = state_dir
rxb_locks_dir()    { printf '%s/locks\n' "$1"; }                       # $1 = state_dir
rxb_index_file()   { printf '%s/index.json\n' "$1"; }                  # $1 = state_dir

# ---- deterministic key + path ---------------------------------------------
# key = first 16 hex of sha256(repo_id \0 type \0 model \0 thread).
# NUL separators avoid collisions between concatenated fields.
rxb_key() { # repo_id type model thread
  printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | sha256sum | cut -c1-16
}

rxb_session_path() { # state_dir type key
  printf '%s/%s/%s.jsonl\n' "$(rxb_sessions_dir "$1")" "$2" "$3"
}

# ---- minimal TOML reader ---------------------------------------------------
# Reads a flat `key = value` (strips one layer of double-quotes) under [section].
# Searches repo override first, then skill defaults. Empty string if not found.
rxb_cfg_get() { # section key
  local section="$1" key="$2" file val=""
  for file in "$RXB_REPO_CFG" "$RXB_DEFAULT_CFG"; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    val=$(awk -v s="$section" -v k="$key" '
      /^[[:space:]]*\[/ {
        cur=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur); next
      }
      cur==s && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
        sub(/^[^=]*=[[:space:]]*/, "")
        sub(/[[:space:]]*(#.*)?$/, "")
        gsub(/^"|"$/, "")
        print; exit
      }' "$file")
    [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  done
  return 1
}

# Resolve which model a request-type uses: explicit override wins, else config.
rxb_model_for() { # type
  if [ -n "${RXB_MODEL_OVERRIDE:-}" ]; then
    printf '%s\n' "$RXB_MODEL_OVERRIDE"; return 0
  fi
  rxb_cfg_get models "$1" || rxb_die "no model mapping for type '$1' (set [models].$1 in config)"
}

# ---- atomic JSON index -----------------------------------------------------
# index.json is an object: { "<key>": { type, thread, model, path, turns,
# created_at, last_used, serve:{addr,pid}? }, ... }.
rxb_index_init() {
  mkdir -p "$(dirname "$RXB_INDEX")"
  [ -f "$RXB_INDEX" ] || printf '{}\n' > "$RXB_INDEX"
}

rxb_index_get() { # key  -> entry json on stdout, or empty + nonzero
  jq -e --arg k "$1" '.[$k] // empty' "$RXB_INDEX" 2>/dev/null
}

# Apply a jq program to the whole index atomically. The program may use $k.
# Read+write+replace happen under one flock so concurrent writers don't clobber.
rxb_index_apply() { # key jq_program
  local k="$1" prog="$2" tmp
  rxb_index_init
  (
    flock 9
    tmp=$(mktemp "${RXB_INDEX}.XXXXXX")
    if jq --arg k "$k" "$prog" "$RXB_INDEX" > "$tmp"; then
      mv "$tmp" "$RXB_INDEX"
    else
      rm -f "$tmp"; return 1
    fi
  ) 9>"${RXB_INDEX}.lock"
}

rxb_now() { date +%s; }

# ---- environment bootstrap -------------------------------------------------
# Call once after sourcing, with the chosen repo dir, to populate path globals.
rxb_init_paths() { # repo_dir
  RXB_REPO_ID=$(rxb_repo_id "${1:-$PWD}")
  RXB_STATE=$(rxb_state_dir "$RXB_REPO_ID")
  RXB_INDEX=$(rxb_index_file "$RXB_STATE")
  RXB_REPO_CFG="$RXB_STATE/config.toml"
  RXB_DEFAULT_CFG="$(rxb_skill_root)/config.defaults.toml"
  export RXB_REPO_ID RXB_STATE RXB_INDEX RXB_REPO_CFG RXB_DEFAULT_CFG
}
