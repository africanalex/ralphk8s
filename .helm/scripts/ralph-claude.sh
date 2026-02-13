#!/bin/bash
# ralph.sh - Long-running Ralph loop for Claude Code
#
# Usage:
#   ./ralph.sh [run_name] [max_iterations]
#
# Arguments:
# - run_name: Optional identifier for this run (used in logs)
# - max_iterations: Maximum Claude iterations (default: 10)
#
# Environment Variables:
# - RALPH_WORK_DIR: Working directory for prd.json/progress (default: current dir)
# - RALPH_PROMPT_FILE: Path to prompt.md (default: ./prompt.md)
#                      Falls back to /etc/ralph/prompt.md if not found
# - AI_MODEL: Preferred model name (overrides CLAUDE_MODEL)
# - AI_TIMEOUT: Execution timeout in seconds (overrides CLAUDE_TIMEOUT)
#
# Assumptions:
# - prd.json and prd-progress.txt are in RALPH_WORK_DIR (or current dir)
# - prompt.md can be in repo root or at /etc/ralph/prompt.md
# - Claude is available as `claude` on PATH.
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
# Prefers AI_MODEL/AI_TIMEOUT from Job, falling back to CLAUDE_* or defaults
CLAUDE_MODEL="${AI_MODEL:-${CLAUDE_MODEL:-claude-sonnet-4-5-20250929}}"
CLAUDE_TIMEOUT="${AI_TIMEOUT:-${CLAUDE_TIMEOUT:-600}}"  # seconds

CLAUDE_ARGS=(
  --dangerously-skip-permissions
  --model "$CLAUDE_MODEL"
)

# Rate-limit and retry configuration
CLAUDE_RATE_LIMIT_BUFFER="${CLAUDE_RATE_LIMIT_BUFFER:-120}"  # seconds
FALLBACK_SLEEP_SECONDS="${FALLBACK_SLEEP_SECONDS:-3600}"      # seconds
MAX_RATE_LIMIT_RETRIES="${MAX_RATE_LIMIT_RETRIES:-3}"
MAX_TIMEOUT_RETRIES="${MAX_TIMEOUT_RETRIES:-3}"
TIMEOUT_RETRY_SLEEP="${TIMEOUT_RETRY_SLEEP:-60}"  # seconds to wait before retry
API_ERROR_SLEEP_SECONDS="${API_ERROR_SLEEP_SECONDS:-1800}"  # 30 minutes
MAX_API_ERROR_RETRIES="${MAX_API_ERROR_RETRIES:-10}"  # Allow many retries for transient API errors
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
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $msg" >> "$RALPH_LOG_FILE"
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

# Detect API 500 Internal Server Error
is_api_error_500() {
  local output="$1"
  echo "$output" | grep -qi "API Error: 500" && \
    echo "$output" | grep -qi '"type":"api_error"' && \
    echo "$output" | grep -qi '"message":"Internal server error"'
}

# Broad rate-limit detection (provider wording varies).
is_rate_limited() {
    local output="$1"
  echo "$output" | grep -Eqi \
    "resets( at)?[[:space:]]+[^[:space:]]+[[:space:]]+UTC"
}

# Try to extract reset time from output.
# Returns:
# - TOD:<time> e.g. TOD:7pm
# - TS:<timestamp> e.g. TS:2026-01-14T19:00:00Z or TS:2026-01-14 19:00 UTC
# - empty if not found
extract_reset_marker() {
  local output="$1"

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

  echo ""
  return 1
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
  require_bin claude

  # Validate input files exist and are readable
  validate_input_files || exit 1

  # Validate prd.json is valid JSON with required fields
  validate_prd_json || exit 1

  init_progress_file_if_needed
  echo "Starting Ralph${RUN_NAME:+ ($RUN_NAME)} - Max iterations: $MAX_ITERATIONS"
  echo "  Model: $CLAUDE_MODEL"
  echo "  Timeout: ${CLAUDE_TIMEOUT}s"
  echo "  Prompt: $PROMPT_FILE"
  echo "  Work dir: $WORK_DIR"
  echo "  Max rate-limit retries: $MAX_RATE_LIMIT_RETRIES"
  echo "  Max timeout retries: $MAX_TIMEOUT_RETRIES"
  echo "  Max API error retries: $MAX_API_ERROR_RETRIES"
  echo "  API error sleep: ${API_ERROR_SLEEP_SECONDS}s (30 minutes)"
  log_note "Ralph started${RUN_NAME:+ ($RUN_NAME)}. Max iterations: $MAX_ITERATIONS. Model: $CLAUDE_MODEL. Prompt: $PROMPT_FILE"

  local i=1
  local rate_limit_retries=0
  local timeout_retries=0
  local api_error_retries=0
  
  while (( i <= MAX_ITERATIONS )); do
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Ralph Iteration $i of $MAX_ITERATIONS - $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "═══════════════════════════════════════════════════════"

    # Rotate log if needed
    rotate_log_if_needed

    # Run Claude with the prompt. Capture output for limit/completion detection.
    # Note: do not let a non-zero exit end the loop; we handle it.
    set +e
    OUTPUT="$(
      timeout --kill-after=30 "$CLAUDE_TIMEOUT" \
        sh -c 'claude "$@" 2>&1 | tee /dev/stderr' _ "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE"
    )"
    CLAUDE_RC=$?
    set -e

    # Check if timeout occurred
    if (( CLAUDE_RC == 124 )); then
      if (( timeout_retries < MAX_TIMEOUT_RETRIES )); then
        timeout_retries=$((timeout_retries + 1))
        echo ""
        echo "WARNING: Claude invocation timed out after ${CLAUDE_TIMEOUT}s (Retry $timeout_retries of $MAX_TIMEOUT_RETRIES)"
        log_note "Claude timed out after ${CLAUDE_TIMEOUT}s. Retry $timeout_retries/$MAX_TIMEOUT_RETRIES. Sleeping ${TIMEOUT_RETRY_SLEEP}s before retry..."
        sleep "$TIMEOUT_RETRY_SLEEP"
        echo ""
        echo "Retrying iteration $i after timeout..."
        # Retry same iteration index
        continue
      else
        echo ""
        echo "ERROR: Claude invocation timed out after ${CLAUDE_TIMEOUT}s. Max timeout retries ($MAX_TIMEOUT_RETRIES) exceeded on iteration $i"
        log_note "Claude timed out after ${CLAUDE_TIMEOUT}s. Max timeout retries exceeded. Exiting."
        exit 1
      fi
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

    # API 500 error detection and retry with 30-minute backoff
    if is_api_error_500 "$OUTPUT"; then
      if (( api_error_retries < MAX_API_ERROR_RETRIES )); then
        api_error_retries=$((api_error_retries + 1))
        echo ""
        echo "API 500 Internal Server Error detected. (Retry $api_error_retries of $MAX_API_ERROR_RETRIES)"
        log_note "API 500 error detected. Retry $api_error_retries/$MAX_API_ERROR_RETRIES. Claude exit code: $CLAUDE_RC"
        
        local sleep_minutes=$(( API_ERROR_SLEEP_SECONDS / 60 ))
        echo "   Sleeping for ${sleep_minutes} minutes before retry..."
        echo "   Will resume at: $(date -u -d "+${API_ERROR_SLEEP_SECONDS} seconds" +"%Y-%m-%d %H:%M:%S UTC")"
        
        log_note "Sleeping ${API_ERROR_SLEEP_SECONDS}s (30 minutes) due to API 500 error"
        sleep "$API_ERROR_SLEEP_SECONDS"
        
        echo ""
        echo "Sleep complete - retrying iteration $i..."
        # Retry same iteration index
        continue
      else
        echo ""
        echo "ERROR: Max API error retries ($MAX_API_ERROR_RETRIES) exceeded on iteration $i"
        log_note "Max API error retries exceeded. Exiting."
        exit 1
      fi
    fi

    # Rate limit detection and sleep-until-reset
    if is_rate_limited "$OUTPUT"; then
      if (( rate_limit_retries < MAX_RATE_LIMIT_RETRIES )); then
        rate_limit_retries=$((rate_limit_retries + 1))
        echo ""
        echo "Rate limit hit detected. (Retry $rate_limit_retries of $MAX_RATE_LIMIT_RETRIES)"
        log_note "Rate limit detected. Retry $rate_limit_retries/$MAX_RATE_LIMIT_RETRIES. Claude exit code: $CLAUDE_RC"

        RESET_MARKER="$(extract_reset_marker "$OUTPUT" || true)"
        if [[ -n "$RESET_MARKER" ]]; then
          SLEEP_SECONDS=""
          case "$RESET_MARKER" in
            TOD:*)
              RESET_TOD="${RESET_MARKER#TOD:}"
              SLEEP_SECONDS="$(calculate_sleep_until_utc_tod "$RESET_TOD" "$CLAUDE_RATE_LIMIT_BUFFER" || true)"
              [[ -n "$SLEEP_SECONDS" ]] && echo "   Limit resets at: $RESET_TOD (assumed UTC time-of-day)"
              ;;
            TS:*)
              RESET_TS="${RESET_MARKER#TS:}"
              SLEEP_SECONDS="$(calculate_sleep_until_utc_timestamp "$RESET_TS" "$CLAUDE_RATE_LIMIT_BUFFER" || true)"
              [[ -n "$SLEEP_SECONDS" ]] && echo "   Limit resets at: $RESET_TS (UTC)"
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

    # Reset retry counters on successful completion of iteration
    rate_limit_retries=0
    timeout_retries=0
    api_error_retries=0

    # Non-rate-limit failure handling:
    # If Claude exits non-zero but no rate limit message, we still continue.
    if (( CLAUDE_RC != 0 )); then
      log_note "Claude exited non-zero (rc=$CLAUDE_RC) without rate-limit detection."
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