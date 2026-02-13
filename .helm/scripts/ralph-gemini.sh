#!/bin/bash
# ralph-gemini.sh - Long-running Ralph loop for Gemini
#
# Usage:
#   ./ralph-gemini.sh [run_name] [max_iterations]
#
# Arguments:
# - run_name: Optional identifier for this run (used in logs)
# - max_iterations: Maximum Gemini iterations (default: 10)
#
# Environment Variables:
# - RALPH_WORK_DIR: Working directory for prd.json/progress (default: current dir)
# - RALPH_PROMPT_FILE: Path to prompt.md (default: ./prompt.md)
#                      Falls back to /etc/ralph/prompt.md if not found
# - AI_MODEL: Preferred model name (overrides GEMINI_MODEL)
# - AI_TIMEOUT: Execution timeout in seconds (overrides GEMINI_TIMEOUT)
#
# Assumptions:
# - prd.json and prd-progress.txt are in RALPH_WORK_DIR (or current dir)
# - prompt.md can be in repo root or at /etc/ralph/prompt.md
# - Gemini is available as `gemini` on PATH.
# - Tasks/state are stored in prd.json (tasks schema)

set -euo pipefail

# Parse arguments: [run_name] [max_iterations]
# If first arg is numeric, treat as max_iterations (backwards compatible)
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  RUN_NAME=""
  MAX_ITERATIONS="${1:-10}"
else
  RUN_NAME="${1:-}"
  MAX_ITERATIONS="${2:-10}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${RALPH_WORK_DIR:-$(pwd)}"
PRD_FILE="$WORK_DIR/prd/$PRD-prd.json"
RALPH_LOG_FILE="$WORK_DIR/ralph-log.txt"

# Prompt file resolution:
# 1. Check RALPH_PROMPT_FILE env var
# 2. Check ./prompt.md in repo
# 3. Fall back to /etc/ralph/system-prompt.md (shared default)
PROMPT_FILE="${RALPH_PROMPT_FILE:-$SCRIPT_DIR/prompt.md}"
if [[ ! -f "$PROMPT_FILE" ]]; then
  DEFAULT_PROMPT_FILE="/etc/ralph/system-prompt.md"
  if [[ -f "$DEFAULT_PROMPT_FILE" ]]; then
    PROMPT_FILE="$DEFAULT_PROMPT_FILE"
    echo "Using default prompt from: $DEFAULT_PROMPT_FILE"
  fi
fi

# AI options (override via env)
# Prefers AI_MODEL/AI_TIMEOUT from Job, falling back to GEMINI_* or defaults
GEMINI_MODEL="${AI_MODEL:-${GEMINI_MODEL:-gemini-3-pro-preview}}"
GEMINI_TIMEOUT="${AI_TIMEOUT:-${GEMINI_TIMEOUT:-600}}"  # seconds

GEMINI_ARGS=(
  --model "$GEMINI_MODEL"
  --yolo
)

# Rate-limit and retry configuration
GEMINI_RATE_LIMIT_BUFFER="${GEMINI_RATE_LIMIT_BUFFER:-120}"  # seconds
FALLBACK_SLEEP_SECONDS="${FALLBACK_SLEEP_SECONDS:-3600}"      # seconds
MAX_RATE_LIMIT_RETRIES="${MAX_RATE_LIMIT_RETRIES:-3}"
LOG_ROTATION_SIZE_MB="${LOG_ROTATION_SIZE_MB:-10}"

########################################
# Helpers
########################################

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required binary: $1" >&2
    exit 1
  }
}

init_progress_file_if_needed() {
  if [[ ! -f "$RALPH_LOG_FILE" ]]; then
    echo "# Ralph Progress Log" > "$RALPH_LOG_FILE"
    echo "Started: $(date)" >> "$RALPH_LOG_FILE"
    echo "---" >> "$RALPH_LOG_FILE"
  fi
}

log_note() {
  # Operational log line appended to progress file
  local msg="$*"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $msg" >> "$RALPH_LOG_FILE"
}

rotate_log_if_needed() {
  local max_size=$((LOG_ROTATION_SIZE_MB * 1024 * 1024))
  
  if [[ ! -f "$RALPH_LOG_FILE" ]]; then
    return 0
  fi
  
  # Get file size
  local file_size
  file_size=$(stat -c%s "$RALPH_LOG_FILE" 2>/dev/null || echo 0)
  
  if (( file_size > max_size )); then
    local timestamp
    timestamp=$(date +%s)
    
    # Archive old log
    mv "$RALPH_LOG_FILE" "${RALPH_LOG_FILE}.${timestamp}"
    
    # Try to gzip (if available)
    if command -v gzip >/dev/null 2>&1; then
      gzip "${RALPH_LOG_FILE}.${timestamp}" 2>/dev/null || true
    fi
    
    # Create new log
    init_progress_file_if_needed
    log_note "Log rotated. Previous log: ${RALPH_LOG_FILE}.${timestamp}"
  fi
}

validate_input_files() {
  # Check prd.json
  if [[ ! -f "$PRD_FILE" ]]; then
    echo "ERROR: $PRD_FILE not found" >&2
    return 1
  fi
  if [[ ! -r "$PRD_FILE" ]]; then
    echo "ERROR: $PRD_FILE not readable" >&2
    return 1
  fi
  
  # Check prompt.md
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: $PROMPT_FILE not found" >&2
    echo "  Checked: $SCRIPT_DIR/prompt.md and /etc/ralph/prompt.md" >&2
    return 1
  fi
  if [[ ! -r "$PROMPT_FILE" ]]; then
    echo "ERROR: $PROMPT_FILE not readable" >&2
    return 1
  fi
  if [[ ! -s "$PROMPT_FILE" ]]; then
    echo "ERROR: $PROMPT_FILE is empty" >&2
    return 1
  fi
  
  return 0
}

validate_prd_json() {
  if ! jq empty "$PRD_FILE" 2>/dev/null; then
    echo "ERROR: $PRD_FILE is not valid JSON" >&2
    return 1
  fi
  
  # Validate required fields
  if ! jq -e 'has("activeTaskId")' "$PRD_FILE" >/dev/null 2>&1; then
    echo "ERROR: $PRD_FILE missing required field: activeTaskId" >&2
    return 1
  fi
  
  if ! jq -e 'has("tasks") and (.tasks | type == "array")' "$PRD_FILE" >/dev/null 2>&1; then
    echo "ERROR: $PRD_FILE missing required field: tasks (array)" >&2
    return 1
  fi
  
  return 0
}

# Broad rate-limit detection (provider wording varies).
is_rate_limited() {
  local output="$1"
  echo "DEBUG: Checking output for rate limit (first 500 chars):" >&2
  echo "$output" | head -c 500 >&2
  echo "" >&2
  echo "$output" | grep -Eqi \
    "hit your limit|rate limit|too many requests|try again later|please wait|quota exceeded|limit resets|resets at"
}

# Try to extract reset time from output.
# Returns:
# - TOD:<time> e.g. TOD:7pm
# - TS:<timestamp> e.g. TS:2026-01-14T19:00:00Z or TS:2026-01-14 19:00 UTC
# - DUR:<duration> e.g. DUR:13h51m3s
# - MS:<milliseconds> e.g. MS:49863045.314239
# - empty if not found
extract_reset_marker() {
  local output="$1"

  # "retryDelayMs: 49863045.314239" (most precise)
  local ms
  ms="$(echo "$output" | grep -oE 'retryDelayMs:[[:space:]]*[0-9.]+' | head -n1 | sed -E 's/^retryDelayMs:[[:space:]]*//')"
  if [[ -n "$ms" ]]; then
    echo "MS:$ms"
    return 0
  fi

  # "resets 7pm" or "resets 7:30am"
  local tod
  tod="$(echo "$output" | grep -oE 'resets[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[ap]m' | head -n1 | sed -E 's/^resets[[:space:]]+//')"
  if [[ -n "$tod" ]]; then
    echo "TOD:$tod"
    return 0
  fi

  # "resets at 19:00 UTC"
  local hhmm
  hhmm="$(echo "$output" | grep -oE 'resets( at)?[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]+UTC' | head -n1 | sed -E 's/^resets( at)?[[:space:]]+//; s/[[:space:]]+UTC$//')"
  if [[ -n "$hhmm" ]]; then
    local today
    today="$(date -u +%Y-%m-%d)"
    echo "TS:${today} ${hhmm} UTC"
    return 0
  fi

  # ISO timestamp "2026-01-14T19:00:00Z"
  local iso
  iso="$(echo "$output" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' | head -n1)"
  if [[ -n "$iso" ]]; then
    echo "TS:$iso"
    return 0
  fi

  # "2026-01-14 19:00 UTC"
  local ts2
  ts2="$(echo "$output" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}[[:space:]]+UTC' | head -n1)"
  if [[ -n "$ts2" ]]; then
    echo "TS:$ts2"
    return 0
  fi

  # "reset after 13h51m3s"
  local dur
  dur="$(echo "$output" | grep -oE 'reset after [0-9hms]+' | head -n1 | sed -E 's/^reset after //')"
  if [[ -n "$dur" ]]; then
    echo "DUR:$dur"
    return 0
  fi

  echo ""
  return 1
}

# Parse a duration like "13h51m3s" and return total seconds (+ buffer).
calculate_sleep_from_duration() {
  local dur_str="$1"
  local buffer="${2:-120}"
  local h=0 m=0 s=0

  # Extract hours, minutes, seconds using regex
  if [[ "$dur_str" =~ ([0-9]+)h ]]; then h="${BASH_REMATCH[1]}"; fi
  if [[ "$dur_str" =~ ([0-9]+)m ]]; then m="${BASH_REMATCH[1]}"; fi
  if [[ "$dur_str" =~ ([0-9]+)s ]]; then s="${BASH_REMATCH[1]}"; fi

  local total_seconds=$(( h * 3600 + m * 60 + s + buffer ))
  
  if (( total_seconds < 60 )); then
    total_seconds=60
  fi
  echo "$total_seconds"
}

# Parse milliseconds and return seconds (+ buffer).
calculate_sleep_from_ms() {
  local ms="$1"
  local buffer="${2:-120}"
  
  # Bash doesn't do floats, so we'll use awk or just truncate
  local seconds
  seconds=$(echo "$ms" | awk '{print int($1 / 1000)}')
  
  local total_seconds=$(( seconds + buffer ))
  if (( total_seconds < 60 )); then
    total_seconds=60
  fi
  echo "$total_seconds"
}

# Parse a "7pm" / "7:30am" time-of-day (UTC) and return seconds until then (+ buffer).
calculate_sleep_until_utc_tod() {
  local time_str="$1"
  local buffer="${2:-120}"
  local now_epoch today_ymd target_epoch

  # Validate time format (HH:MM[ap]m or H[ap]m)
  local time_regex='^(1[0-2]|[1-9])(:[0-5][0-9])?[ap]m$'

  # Normalize "7pm" -> "7:00pm"
  if echo "$time_str" | grep -Eq '^[0-9]{1,2}[ap]m$'; then
    time_str="$(echo "$time_str" | sed -E 's/^([0-9]{1,2})([ap]m)$/\1:00\2/')"
  fi

  # Validate normalized format
  if ! echo "$time_str" | grep -Eq "$time_regex"; then
    echo "ERROR: Invalid time format: $1 (expected HH:MM[ap]m or H[ap]m)" >&2
    return 1
  fi

  now_epoch="$(date -u +%s)"
  today_ymd="$(date -u +%Y-%m-%d)"

  target_epoch="$(date -u -d "${today_ymd} ${time_str} UTC" +%s 2>/dev/null || echo "")"
  if [[ -z "$target_epoch" ]]; then
    echo "ERROR: Could not parse time: $time_str" >&2
    return 1
  fi

  # If already passed today, schedule for tomorrow
  if (( target_epoch <= now_epoch )); then
    target_epoch="$(date -u -d "${today_ymd} ${time_str} UTC +1 day" +%s 2>/dev/null || echo "")"
    if [[ -z "$target_epoch" ]]; then
      return 1
    fi
  fi

  local sleep_seconds=$(( target_epoch - now_epoch + buffer ))
  if (( sleep_seconds < 60 )); then
    sleep_seconds=60
  fi
  echo "$sleep_seconds"
}

# Parse an ISO-ish timestamp and return seconds until then (+ buffer).
calculate_sleep_until_utc_timestamp() {
  local ts="$1"
  local buffer="${2:-120}"

  local now_epoch target_epoch
  now_epoch="$(date -u +%s)"
  target_epoch="$(date -u -d "$ts" +%s 2>/dev/null || echo "")"
  if [[ -z "$target_epoch" ]]; then
    echo "ERROR: Could not parse timestamp: $ts" >&2
    return 1
  fi

  local sleep_seconds=$(( target_epoch - now_epoch + buffer ))
  if (( sleep_seconds < 60 )); then
    sleep_seconds=60
  fi
  echo "$sleep_seconds"
}

########################################
# Main
########################################

main() {
  require_bin jq
  require_bin grep
  require_bin sed
  require_bin awk
  require_bin tee
  require_bin timeout
  require_bin gemini

  # Validate input files exist and are readable
  validate_input_files || exit 1

  # Validate prd.json is valid JSON with required fields
  validate_prd_json || exit 1

  init_progress_file_if_needed
  echo "Starting Ralph${RUN_NAME:+ ($RUN_NAME)} - Max iterations: $MAX_ITERATIONS"
  echo "  Model: $GEMINI_MODEL"
  echo "  Timeout: ${GEMINI_TIMEOUT}s"
  echo "  Prompt: $PROMPT_FILE"
  echo "  Work dir: $WORK_DIR"
  echo "  Max rate-limit retries: $MAX_RATE_LIMIT_RETRIES"
  log_note "Ralph started${RUN_NAME:+ ($RUN_NAME)}. Max iterations: $MAX_ITERATIONS. Model: $GEMINI_MODEL. Prompt: $PROMPT_FILE"

  local i=1
  local rate_limit_retries=0
  
  while (( i <= MAX_ITERATIONS )); do
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Ralph Iteration $i of $MAX_ITERATIONS"
    echo "═══════════════════════════════════════════════════════"

    # Rotate log if needed
    rotate_log_if_needed

    # Run Gemini with the prompt. Capture output for limit/completion detection.
    # Note: do not let a non-zero exit end the loop; we handle it.
    set +e
    OUTPUT="$(
      timeout "$GEMINI_TIMEOUT" \
        gemini "${GEMINI_ARGS[@]}" < "$PROMPT_FILE" 2>&1 \
        | tee /dev/stderr
    )"
    GEMINI_RC=$?
    set -e

    # Check if timeout occurred
    if (( GEMINI_RC == 124 )); then
      echo ""
      echo "ERROR: Gemini invocation timed out after ${GEMINI_TIMEOUT}s"
      log_note "Gemini timed out after ${GEMINI_TIMEOUT}s. Exiting."
      exit 1
    fi

    # Completion sentinel (EXACT match only, ignoring surrounding whitespace)
    if printf '%s' "$OUTPUT" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | \
      grep -qx '<promise>COMPLETE</promise>'; then
      echo ""
      echo "Ralph completed all tasks!"
      echo "Completed at iteration $i of $MAX_ITERATIONS"
      log_note "COMPLETE detected (exact match). Exiting successfully."
      exit 0
    fi

    # Failure sentinel (EXACT match only, ignoring surrounding whitespace)
    if printf '%s' "$OUTPUT" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | \
      grep -qx '<promise>FAIL</promise>'; then
      echo ""
      echo "Ralph received FAIL sentinel. Exiting with error."
      log_note "FAIL detected (exact match). Exiting with error."
      exit 1
    fi

    # Rate limit detection and sleep-until-reset
    if is_rate_limited "$OUTPUT"; then
      if (( rate_limit_retries < MAX_RATE_LIMIT_RETRIES )); then
        rate_limit_retries=$((rate_limit_retries + 1))
        echo ""
        echo "Rate limit hit detected. (Retry $rate_limit_retries of $MAX_RATE_LIMIT_RETRIES)"
        log_note "Rate limit detected. Retry $rate_limit_retries/$MAX_RATE_LIMIT_RETRIES. Gemini exit code: $GEMINI_RC"

        RESET_MARKER="$(extract_reset_marker "$OUTPUT" || true)"
        if [[ -n "$RESET_MARKER" ]]; then
          SLEEP_SECONDS=""
          case "$RESET_MARKER" in
            TOD:*) 
              RESET_TOD="${RESET_MARKER#TOD:}"
              SLEEP_SECONDS="$(calculate_sleep_until_utc_tod "$RESET_TOD" "$GEMINI_RATE_LIMIT_BUFFER" || true)"
              [[ -n "$SLEEP_SECONDS" ]] && echo "   Limit resets at: $RESET_TOD (assumed UTC time-of-day)"
              ;; 
            TS:*) 
              RESET_TS="${RESET_MARKER#TS:}"
              SLEEP_SECONDS="$(calculate_sleep_until_utc_timestamp "$RESET_TS" "$GEMINI_RATE_LIMIT_BUFFER" || true)"
              [[ -n "$SLEEP_SECONDS" ]] && echo "   Limit resets at: $RESET_TS (UTC)"
              ;; 
            DUR:*)
              RESET_DUR="${RESET_MARKER#DUR:}"
              SLEEP_SECONDS="$(calculate_sleep_from_duration "$RESET_DUR" "$GEMINI_RATE_LIMIT_BUFFER" || true)"
              [[ -n "$SLEEP_SECONDS" ]] && echo "   Limit resets after: $RESET_DUR"
              ;;
            MS:*)
              RESET_MS="${RESET_MARKER#MS:}"
              SLEEP_SECONDS="$(calculate_sleep_from_ms "$RESET_MS" "$GEMINI_RATE_LIMIT_BUFFER" || true)"
              [[ -n "$SLEEP_SECONDS" ]] && echo "   Limit resets in: $(( ${RESET_MS%.*} / 1000 ))s (from retryDelayMs)"
              ;;
          esac

          if [[ -n "$SLEEP_SECONDS" ]]; then
            local sleep_hours=$(( SLEEP_SECONDS / 3600 ))
            local sleep_minutes=$(( (SLEEP_SECONDS % 3600) / 60 ))

            echo "   Sleeping for ${sleep_hours}h ${sleep_minutes}m (until after reset)..."
            echo "   Will resume at: $(date -u -d "+${SLEEP_SECONDS} seconds" +"%Y-%m-%d %H:%M:%S UTC")"

            log_note "Sleeping ${SLEEP_SECONDS}s due to reset marker: ${RESET_MARKER}"
            sleep "$SLEEP_SECONDS"

            echo ""
            echo "Sleep complete - retrying iteration $i..."
            # Retry same iteration index
            continue
          fi
        fi

        # Fallback sleep
        echo "   Could not parse reset time. Sleeping fallback ${FALLBACK_SLEEP_SECONDS}s..."
        log_note "No parseable reset time. Fallback sleep ${FALLBACK_SLEEP_SECONDS}s."
        sleep "$FALLBACK_SLEEP_SECONDS"
        continue
      else
        echo ""
        echo "ERROR: Max rate-limit retries ($MAX_RATE_LIMIT_RETRIES) exceeded on iteration $i"
        log_note "Max rate-limit retries exceeded. Exiting."
        exit 1
      fi
    fi

    # Reset rate-limit counter on successful completion of iteration
    rate_limit_retries=0

    # Non-rate-limit failure handling:
    # If Gemini exits non-zero but no rate limit message, we still continue.
    if (( GEMINI_RC != 0 )); then
      log_note "Gemini exited non-zero (rc=$GEMINI_RC) without rate-limit detection."
    fi

    echo "Iteration $i complete."
    log_note "Iteration $i complete."

    sleep 2
    i=$((i + 1))
  done

  echo ""
  echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
  echo "Check $RALPH_LOG_FILE for status."
  log_note "Max iterations reached; exiting cleanly (tasks may remain)."
  exit 0
}

main "$@"
