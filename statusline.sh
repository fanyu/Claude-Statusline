#!/bin/bash
set -f

input=$(cat)
[ -z "$input" ] && printf "Claude" && exit 0

# ── jq guard ─────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { printf "statusline: jq not found\n"; exit 1; }

# ── Colors ───────────────────────────────────────────────
model_color='\033[38;2;232;232;232m'
dir_color='\033[38;2;97;175;239m'
branch_color='\033[38;2;152;195;121m'
diff_color='\033[38;2;229;192;123m'
effort_color='\033[38;2;198;120;221m'
two_x_color='\033[38;2;0;217;126m'
label_color='\033[38;2;122;134;153m'
time_color='\033[38;2;200;205;214m'
bar_green='\033[38;2;152;195;121m'
bar_yellow='\033[38;2;229;192;123m'
bar_orange='\033[38;2;209;154;102m'
bar_red='\033[38;2;224;108;117m'
dim='\033[2m'
reset='\033[0m'

FILL="▰"
EMPTY="▱"
BAR_WIDTH=10

sep=" ${dim}·${reset} "

# ── Helpers ──────────────────────────────────────────────

# color_for_remaining <pct>  (higher remaining = greener)
color_for_remaining() {
    local pct=$1
    if   [ "$pct" -ge 70 ]; then printf "%s" "$bar_green"
    elif [ "$pct" -ge 40 ]; then printf "%s" "$bar_yellow"
    elif [ "$pct" -ge 20 ]; then printf "%s" "$bar_orange"
    else                          printf "%s" "$bar_red"
    fi
}

# color_for_used <pct>  (higher used = redder)
color_for_used() {
    local pct=$1
    if   [ "$pct" -ge 80 ]; then printf "%s" "$bar_red"
    elif [ "$pct" -ge 60 ]; then printf "%s" "$bar_orange"
    elif [ "$pct" -ge 40 ]; then printf "%s" "$bar_yellow"
    else                          printf "%s" "$bar_green"
    fi
}

# build_bar <filled_pct> <bar_color>
# filled_pct = how full the bar should be (0-100)
# color = ANSI code for filled portion
build_bar() {
    local pct=$1
    local bar_color="$2"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local filled=$(( pct * BAR_WIDTH / 100 ))
    local empty=$(( BAR_WIDTH - filled ))
    local filled_str="" empty_str=""
    local i
    for ((i=0; i<filled; i++)); do filled_str+="$FILL"; done
    for ((i=0; i<empty;  i++)); do empty_str+="$EMPTY"; done
    printf "%b%s%b%s%b" "$bar_color" "$filled_str" "${dim}" "$empty_str" "$reset"
}

iso_to_epoch() {
    local iso_str="$1"
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    [ -n "$epoch" ] && echo "$epoch" && return 0
    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"; stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi
    [ -n "$epoch" ] && echo "$epoch" && return 0
    return 1
}

format_reset_time() {
    local iso_str="$1" style="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return
    local epoch result
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    printf "%s" "$result"
}

get_oauth_token() {
    [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo "$CLAUDE_CODE_OAUTH_TOKEN" && return 0
    local blob token
    if command -v security >/dev/null 2>&1; then
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$token" ] && [ "$token" != "null" ] && echo "$token" && return 0
        fi
    fi
    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        [ -n "$token" ] && [ "$token" != "null" ] && echo "$token" && return 0
    fi
    if command -v secret-tool >/dev/null 2>&1; then
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$token" ] && [ "$token" != "null" ] && echo "$token" && return 0
        fi
    fi
    echo ""
}

# ── Parse JSON ───────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$ctx_size" -eq 0 ] 2>/dev/null && ctx_size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo  "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current_tokens=$(( input_tokens + cache_create + cache_read ))

if [ "$ctx_size" -gt 0 ]; then
    ctx_pct_used=$(( current_tokens * 100 / ctx_size ))
else
    ctx_pct_used=0
fi

cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)

effort="default"
settings_path="$HOME/.claude/settings.json"
[ -f "$settings_path" ] && effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null || echo "default")

# ── Git info ─────────────────────────────────────────────
project_name=$(basename "$cwd")
git_branch=""
diff_count=0

if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
    diff_count=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | wc -l | tr -d ' ')
fi

# ── 2x detection ─────────────────────────────────────────
pt_day=$(TZ="America/Los_Angeles" date +%u)    # 1=Mon…7=Sun
pt_hour=$(TZ="America/Los_Angeles" date +%-H)  # 0-23
if [ "$pt_day" -ge 6 ]; then
    is_2x=true
elif [ "$pt_hour" -lt 5 ] || [ "$pt_hour" -ge 11 ]; then
    is_2x=true
else
    is_2x=false
fi

# ── Fetch usage (cached 60s) ─────────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt 60 ]; then
        needs_refresh=false
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

if $needs_refresh; then
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
        fi
    fi
    [ -z "$usage_data" ] && [ -f "$cache_file" ] && usage_data=$(cat "$cache_file" 2>/dev/null)
fi

# ── Build Line 1: model · effort · context ───────────────
ctx_bar_color=$(color_for_used "$ctx_pct_used")
ctx_bar=$(build_bar "$ctx_pct_used" "$ctx_bar_color")

case "$effort" in
    high)    effort_sym="◉" ;;
    medium)  effort_sym="◑" ;;
    low)     effort_sym="◔" ;;
    *)       effort_sym="◌" ;;
esac

line1="${model_color}${model_name}${reset}"
line1+="${sep}"
line1+="${effort_color}${effort_sym} ${effort}${reset}"
line1+="${sep}"
line1+="${ctx_bar} ${ctx_bar_color}${ctx_pct_used}%${reset}"

# ── Build Line 2: session · weekly · 2x ──────────────────
line2=""

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    # Session (5-hour)
    five_used=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    five_reset=$(format_reset_time "$five_reset_iso" "time")
    five_left=$(( 100 - five_used ))
    [ "$five_left" -lt 0 ] && five_left=0
    five_bar_color=$(color_for_remaining "$five_left")
    five_bar=$(build_bar "$five_left" "$five_bar_color")

    # Weekly (7-day)
    seven_used=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    seven_reset=$(format_reset_time "$seven_reset_iso" "date")
    seven_left=$(( 100 - seven_used ))
    [ "$seven_left" -lt 0 ] && seven_left=0
    seven_bar_color=$(color_for_remaining "$seven_left")
    seven_bar=$(build_bar "$seven_left" "$seven_bar_color")

    line2="${label_color}session${reset} ${five_bar} ${five_bar_color}${five_left}% left${reset}"
    [ -n "$five_reset" ] && line2+="  ${dim}↺${reset} ${time_color}${five_reset}${reset}"
    line2+="    "
    line2+="${label_color}weekly${reset} ${seven_bar} ${seven_bar_color}${seven_left}% left${reset}"
    [ -n "$seven_reset" ] && line2+="  ${dim}↺${reset} ${time_color}${seven_reset}${reset}"
    line2+="    "
    if $is_2x; then
        line2+="${two_x_color}2x${reset}"
    else
        line2+="${dim}2x${reset}"
    fi

    # Extra billing (if enabled) — appended as continuation of line 2
    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_used_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used_dollars=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
        extra_limit_dollars=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
        extra_left=$(( 100 - extra_used_pct ))
        [ "$extra_left" -lt 0 ] && extra_left=0
        extra_bar_color=$(color_for_remaining "$extra_left")
        extra_bar=$(build_bar "$extra_left" "$extra_bar_color")
        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [ -z "$extra_reset" ] && extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        line2+="    ${label_color}extra${reset} ${extra_bar} ${extra_bar_color}\$${extra_used_dollars}${dim}/${reset}${time_color}\$${extra_limit_dollars}${reset}"
        [ -n "$extra_reset" ] && line2+="  ${dim}↺${reset} ${time_color}${extra_reset}${reset}"
    fi
fi

# ── Build Line 3: project · branch · diff ────────────────
line3="${dir_color}${project_name}${reset}"
if [ -n "$git_branch" ]; then
    line3+="  ${branch_color}${git_branch}${reset}"
fi
if [ "$diff_count" -gt 0 ] 2>/dev/null; then
    line3+="  ${diff_color}±${diff_count}${reset}"
fi

# ── Output ────────────────────────────────────────────────
printf "%b" "$line1"
if [ -n "$line2" ]; then
    printf "\n%b" "$line2"
fi
printf "\n%b" "$line3"
exit 0
