#!/bin/bash
# Based on: https://github.com/daniel3303/ClaudeCodeStatusLine
# Line 1: [account label |] Model (effort) | dir@branch scratchpad | tokens (%used) | cache TTL countdown [· 🫀 autostop (interval)] | 5h[↑] @reset | 7d[↑] @reset | scoped | extra | CLI version
# Line 2: [session name |] full current working directory

set -f

dim=$'\e[2m'
reset=$'\e[0m'
cyan=$'\e[38;2;46;149;153m'
green=$'\e[38;2;0;160;0m'
red=$'\e[38;2;255;85;85m'
orange=$'\e[38;2;255;176;85m'
white=$'\e[38;2;220;220;220m'
sep=" ${dim}|${reset} "

claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cache_dir="/tmp/claude"
usage_cache="$cache_dir/statusline-usage-${claude_config_dir//[^A-Za-z0-9]/_}.cache"
release_cache="$cache_dir/statusline-claude-code-releases.cache"
release_ttl=3600
idle_render_ttl=60

read_cache() {
    cache_time=0
    cache_body=""
    [ -s "$1" ] || return 0
    { read -r cache_time; IFS= read -r -d '' cache_body; } < "$1"
    [[ $cache_time =~ ^[0-9]+$ ]] || cache_time=0
}

read_file() {
    file_body=""
    [ -r "$1" ] && IFS= read -r -d '' file_body < "$1"
    return 0
}

write_cache() {
    printf '%s\n%s' "$2" "$3" > "$1.$$" && mv -f "$1.$$" "$1"
}

extract_access_token() {
    local pattern='"accessToken"[[:space:]]*:[[:space:]]*"([^"]+)"'
    [[ $1 =~ $pattern ]] && token=${BASH_REMATCH[1]}
}

resolve_oauth_token() {
    token=${CLAUDE_CODE_OAUTH_TOKEN:-}
    [ -n "$token" ] && return 0
    if command -v security >/dev/null 2>&1; then
        local service="Claude Code-credentials" dir_hash
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            dir_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256)
            service+="-${dir_hash:0:8}"
        fi
        extract_access_token "$(security find-generic-password -s "$service" -w 2>/dev/null)" && return 0
    fi
    read_file "$claude_config_dir/.credentials.json"
    extract_access_token "$file_body" && return 0
    if command -v secret-tool >/dev/null 2>&1; then
        extract_access_token "$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)" && return 0
    fi
    return 1
}

refresh_usage() {
    resolve_oauth_token || return
    local response
    response=$(curl -sf --connect-timeout 3 --max-time 10 \
        -H "Accept: application/json" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/${cli_version:-2.1.34}" \
        "https://api.anthropic.com/api/oauth/usage")
    case $response in
        *'"limits"'*|*'"five_hour"'*) write_cache "$usage_cache" "$now" "$response" ;;
    esac
}

refresh_releases() {
    local response
    response=$(curl -sf --connect-timeout 3 --max-time 5 \
        "https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags")
    case $response in
        *'"latest"'*) write_cache "$release_cache" "$now" "$response" ;;
    esac
}

resolve_git_dir() {
    local dir=$1 pointer
    while [ -n "$dir" ]; do
        if [ -d "$dir/.git" ]; then
            git_dir="$dir/.git"
            return 0
        fi
        if [ -f "$dir/.git" ]; then
            read -r pointer < "$dir/.git"
            git_dir=${pointer#gitdir: }
            [[ $git_dir == /* ]] || git_dir="$dir/$git_dir"
            return 0
        fi
        [[ $dir == */* ]] || break
        dir=${dir%/*}
    done
    return 1
}

file_url() {
    local LC_ALL=C path=$1 encoded="" char hex i
    for (( i = 0; i < ${#path}; i++ )); do
        char=${path:i:1}
        case $char in
            [A-Za-z0-9/._~-]) encoded+=$char ;;
            *) printf -v hex '%%%02X' "'$char"; encoded+=$hex ;;
        esac
    done
    url="file://$encoded"
}

hyperlink() {
    file_url "$1"
    link=$'\e]8;;'"$url"$'\e\\'"$2"$'\e]8;;\e\\'
}

resolve_scratchpad_dir() {
    local base sanitized candidate
    scratchpad_dir=""
    [ -n "$session_id" ] && [ -n "$project_dir" ] || return
    base=$(cd "${CLAUDE_CODE_TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return
    sanitized=${project_dir//[^a-zA-Z0-9]/-}
    if (( ${#sanitized} <= 200 )); then
        candidate="$base/claude-$UID/$sanitized/$session_id/scratchpad"
        [ -d "$candidate" ] && scratchpad_dir=$candidate
        return
    fi
    set +f
    for candidate in "$base/claude-$UID/${sanitized:0:200}-"*"/$session_id/scratchpad"; do
        [ -d "$candidate" ] && scratchpad_dir=$candidate && break
    done
    set -f
}

render_cache_segment() {
    local last_epoch ttl remaining color
    [ -r "$transcript_path" ] || return
    read -r last_epoch ttl < <(tail -n 400 "$transcript_path" | jq -nRr '
        [inputs | fromjson? | select(.type == "assistant" and (.isSidechain | not)
            and .message.usage != null and .message.model != "<synthetic>")] as $replies
        | ($replies | last) as $last
        | select($last != null)
        | ([$replies[].message.usage.cache_creation // {}
            | if (.ephemeral_1h_input_tokens // 0) > 0 then 3600
              elif (.ephemeral_5m_input_tokens // 0) > 0 then 300
              else empty end] | last // 300) as $ttl
        | "\($last.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) \($ttl)"
    ' 2>/dev/null)
    [[ $last_epoch =~ ^[0-9]+$ && $ttl =~ ^[0-9]+$ ]] || return
    remaining=$(( last_epoch + ttl - now ))
    if (( remaining <= 0 )); then
        cache_segment="${sep}${white}cache TTL${reset} ${red}expired${reset}"
        return
    fi
    live_cache_ttl=$ttl
    (( remaining * 4 > ttl )) && color=$green || color=$orange
    if (( ttl > 300 )); then
        printf -v cache_segment '%s%scache TTL%s %s%dm%s' "$sep" "$white" "$reset" "$color" $(( (remaining + 59) / 60 )) "$reset"
    else
        printf -v cache_segment '%s%scache TTL%s %s%d:%02d%s' "$sep" "$white" "$reset" "$color" $(( remaining / 60 )) $(( remaining % 60 )) "$reset"
    fi
}

render_cachebeat_segment() {
    local state_file="${TMPDIR:-/tmp}/cachebeat-$session_id" idle_minutes deadline timer_pid remaining minutes countdown color=$dim
    [[ $session_id =~ ^[A-Za-z0-9-]+$ ]] && [ -r "$state_file" ] || return
    read -r _ idle_minutes deadline _ < "$state_file"
    [[ $idle_minutes =~ ^[0-9]+$ && $deadline =~ ^[0-9]+$ ]] || return
    remaining=$(( deadline - now ))
    (( remaining > 0 )) || return
    [ -r "$state_file.pid" ] && read -r timer_pid < "$state_file.pid" \
        && [[ $timer_pid =~ ^[0-9]+$ ]] && kill -0 "$timer_pid" 2>/dev/null && color=$green
    minutes=$(( (remaining + 59) / 60 ))
    if (( minutes >= 60 )); then
        printf -v countdown '%dh%02dm' $(( minutes / 60 )) $(( minutes % 60 ))
    else
        countdown="${minutes}m"
    fi
    if [ -n "$cache_segment" ]; then
        cache_segment+=" ${dim}·${reset} "
    else
        cache_segment+=$sep
    fi
    cache_segment+="🫀 ${color}${countdown}${reset} ${dim}(${reset}${white}${idle_minutes}m${reset}${dim})${reset}"
}

render_git_segment() {
    local head="" summary added=0 removed=0
    local insertions_pattern='([0-9]+) insertion' deletions_pattern='([0-9]+) deletion'
    resolve_git_dir "$cwd" || return
    { read -r head < "$git_dir/HEAD" || [ -n "$head" ]; } 2>/dev/null || return
    if [[ $head == "ref: refs/heads/"* ]]; then
        git_segment+="${dim}@${reset}${green}${head#ref: refs/heads/}${reset}"
    else
        git_segment+="${dim}@${reset}${green}HEAD${reset}"
    fi
    summary=$(git --no-optional-locks -C "$cwd" diff --shortstat 2>/dev/null)
    [[ $summary =~ $insertions_pattern ]] && added=${BASH_REMATCH[1]}
    [[ $summary =~ $deletions_pattern ]] && removed=${BASH_REMATCH[1]}
    (( added + removed > 0 )) && git_segment+=" ${dim}(${reset}${green}+${added}${reset} ${red}-${removed}${reset}${dim})${reset}"
}

input=$(cat)
render_cache=""
session_pattern='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9-]+)"'
if [[ $input =~ $session_pattern ]]; then
    render_cache="$cache_dir/statusline-render-${BASH_REMATCH[1]}"
    read_cache "$render_cache.out"
    if (( cache_time > 0 )); then
        read_file "$render_cache.in"
        if [[ $file_body == "$input" ]] && (( $(date +%s) - cache_time < idle_render_ttl )); then
            printf '%s' "$cache_body"
            exit 0
        fi
    fi
fi

read_cache "$usage_cache"
usage_time=$cache_time
usage_body=$cache_body

release_time=0
releases_body=""
if [ "${STATUSLINE_CHECK_UPDATES:-true}" != "false" ]; then
    read_cache "$release_cache"
    release_time=$cache_time
    releases_body=$cache_body
fi

# Pass large files via --rawfile (not --arg) to avoid "Argument list too long" on Windows
jq_file_args=()
add_file_arg() {
    if [ -r "$2" ]; then jq_file_args+=(--rawfile "$1" "$2"); else jq_file_args+=(--arg "$1" ""); fi
}
add_file_arg settings "$claude_config_dir/settings.json"
add_file_arg account "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

IFS=$'\x1f' read -r now head tokens_segment limits_segment session_segment cwd project_dir session_id transcript_path cli_version has_builtin update_notice < <(
    jq -r --arg usage "$usage_body" --arg releases "$releases_body" "${jq_file_args[@]}" '
def esc($code): "\u001b[\($code)m";
def reset: esc("0");
def dim: esc("2");
def blue: esc("38;2;0;153;255");
def orange: esc("38;2;255;176;85");
def green: esc("38;2;0;160;0");
def red: esc("38;2;255;85;85");
def yellow: esc("38;2;230;200;0");
def purple: esc("38;2;167;139;250");
def white: esc("38;2;220;220;220");
def pink: esc("38;2;255;121;198");
def sep: " \(dim)|\(reset) ";
def usage_color($pct): if $pct >= 90 then red elif $pct >= 70 then orange elif $pct >= 50 then yellow else green end;
def segment($label; $pct): "\(sep)\(white)\($label)\(reset) \(usage_color($pct))\($pct)%\(reset)";
def pace_arrow($pct; $resets; $window):
    if ($resets // 0) > 0 and (($pct // 0) > ((($window - ($resets - now)) / $window * 100) | if . < 0 then 0 elif . > 100 then 100 else . end))
    then "\(red)↑\(reset)" else "" end;
def limit_segment($label; $pct; $resets; $window): segment($label; $pct // 0 | round) + pace_arrow($pct; $resets; $window);
def placeholder($label): "\(sep)\(white)\($label)\(reset) \(dim)-\(reset)";
def tokens:
    if . >= 1000000 then ((. / 100000 | round) / 10) as $v | "\(if $v == ($v | floor) then $v | floor else $v end)m"
    elif . >= 1000 then "\(. / 1000 | round)k"
    else "\(.)" end;
def two_decimals: (. * 100 | round) as $c | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
def day_of_month: strflocaltime("%d") | tonumber | tostring;
def at_time: " \(dim)@\(strflocaltime("%H:%M"))\(reset)";
def at_datetime: " \(dim)@\(strflocaltime("%a %b ") + day_of_month + strflocaltime(", %H:%M"))\(reset)";
def at_epoch(f): if (. // 0) > 0 then f else "" end;
def semver: ltrimstr("v") | split(".") | map(tonumber? // 0) | (. + [0, 0, 0])[0:3];
def iso_to_epoch:
    try (capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(Z|(?<sign>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))?$")
        | ((.base + "Z") | fromdateiso8601)
          - (if .sign == null then 0 else (if .sign == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end))
    catch null;

. as $in
| (($usage | fromjson?) // null) as $u
| ((($u | objects | (.limits or .five_hour)) // false)) as $api_ok
| ($in.rate_limits.five_hour // {}) as $bf
| ($in.rate_limits.seven_day // {}) as $bs
| ($bf.used_percentage != null or $bs.used_percentage != null) as $has_builtin
| ($has_builtin and (
      (($bf.used_percentage // 0) | round) != 0 or (($bs.used_percentage // 0) | round) != 0
      or ($bf.resets_at // 0) != 0 or ($bs.resets_at // 0) != 0)) as $use_builtin

| def api_limit($kind; $bucket; $field):
      ([$u.limits[]? | select(.kind == $kind and .resets_at != null)][0][$field])
      // $u[$bucket][if $field == "percent" then "utilization" else $field end];
  def scoped_limits:
      [$u.limits[]? | select(.kind == "weekly_scoped")
       | segment(.scope.model.display_name // "scoped"; (.percent // 0) | round)] | join("");
  def extra_usage:
      ($u.extra_usage // {}) | if .is_enabled == true then
          ((.utilization // 0) | round) as $pct
          | "\(sep)\(white)extra\(reset) \(usage_color($pct))$\((.used_credits // 0) / 100 | two_decimals)/$\((.monthly_limit // 0) / 100 | two_decimals)\(reset)"
      else "" end;

  ($in.model.display_name // "Claude" | sub(" *\\((?<n>[0-9.]*[kKmM]*) context\\)"; " \(.n)")) as $model
| ($in.effort.level
   // ($ENV.CLAUDE_CODE_EFFORT_LEVEL | select(. != null and . != ""))
   // ($settings | fromjson? | .effortLevel)
   // "medium") as $effort
| ({low: [dim, "low"], medium: [orange, "med"], high: [green, "high"], xhigh: [purple, "xhigh"], max: [red, "max"]}[$effort]
   // [green, $effort]) as [$effort_color, $effort_label]

| ($in.context_window.context_window_size // 200000 | if . == 0 then 200000 else . end) as $size
| ($in.context_window.current_usage // {}
   | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) as $current

| (if $use_builtin then
      (if $bf.used_percentage != null then limit_segment("5h"; $bf.used_percentage; $bf.resets_at; 18000) + ($bf.resets_at | at_epoch(at_time)) else "" end)
    + (if $bs.used_percentage != null then limit_segment("7d"; $bs.used_percentage; $bs.resets_at; 604800) + ($bs.resets_at | at_epoch(at_datetime)) else "" end)
    + scoped_limits + extra_usage
   elif $api_ok then
      (api_limit("session"; "five_hour"; "resets_at") | iso_to_epoch) as $five_reset
    | (api_limit("weekly_all"; "seven_day"; "resets_at") | iso_to_epoch) as $seven_reset
    | limit_segment("5h"; api_limit("session"; "five_hour"; "percent"); $five_reset; 18000)
    + ($five_reset | at_epoch(at_time))
    + limit_segment("7d"; api_limit("weekly_all"; "seven_day"; "percent"); $seven_reset; 604800)
    + ($seven_reset | at_epoch(at_datetime))
    + scoped_limits + extra_usage
   else placeholder("5h") + placeholder("7d") end) as $limits

| ($in.session_name // "" | tostring | gsub("[[:cntrl:]]"; "")) as $session_name
| (($account | fromjson? | .oauthAccount) // {}) as $oauth_account
| (($ENV.STATUSLINE_ACCOUNT_LABEL | strings | select(. != ""))
   // ($oauth_account.displayName | strings | select(. != ""))
   // ($oauth_account.emailAddress // "" | tostring | split("@") | .[1] // "")
   | gsub("[[:cntrl:]]"; "")) as $account_label
| (if $account_label != "" then "\(pink)\($account_label)\(reset)\(sep)" else "" end) as $account_prefix

| [ (now | floor | tostring),
    "\($account_prefix)\(blue)\($model)\(reset) \(dim)(\(reset)\($effort_color)\($effort_label)\(reset)\(dim))\(reset)",
    "\(sep)\(orange)\($current | tokens)/\($size | tokens)\(reset) \(dim)(\(reset)\(green)\($current * 100 / $size | floor)%\(reset)\(dim))\(reset)",
    $limits,
    (if $session_name != "" then "\(white)\($session_name)\(reset)" else "" end),
    ($in.cwd // ""),
    ($in.workspace.project_dir // $in.cwd // ""),
    ($in.session_id // ""),
    ($in.transcript_path // ""),
    ($in.version // ""),
    ($has_builtin | tostring),
    ((($releases | fromjson?) // {})[($settings | fromjson? | .autoUpdatesChannel) // "latest"] // "") as $available
    | if $available != "" and ($in.version // "") != "" and ($available | semver) > ($in.version | semver)
      then "\(dim)Claude Code update available: v\($in.version) → \(orange)v\($available)\(reset)\(dim) (run: claude update)\(reset)"
      else "" end
  ] | join("\u001f")
' 2>/dev/null <<< "$input"
)

if [ -z "$now" ]; then
    printf "Claude"
    exit 0
fi

cwd=${cwd//\\//}
git_segment=""
if [ -n "$cwd" ]; then
    hyperlink "$cwd" "${cyan}${cwd##*/}${reset}"
    git_segment="${sep}${link}"
    render_git_segment
    resolve_scratchpad_dir
    if [ -n "$scratchpad_dir" ]; then
        hyperlink "$scratchpad_dir" "${dim}${cyan}scratchpad${reset}"
        git_segment+=" ${link}"
    fi
fi

cache_segment=""
live_cache_ttl=0
render_cache_segment
render_cachebeat_segment

output="${head}${git_segment}${tokens_segment}${cache_segment}${limits_segment}"
[ -n "$cli_version" ] && output+="${sep}${orange}v${cli_version}${reset}"
second_line=""
[ -n "$session_segment" ] && second_line="$session_segment"
[ -n "$session_segment" ] && [ -n "$cwd" ] && second_line+="$sep"
[ -n "$cwd" ] && second_line+="${dim}${cwd}${reset}"
[ -n "$second_line" ] && output+=$'\n'"$second_line"
[ -n "$update_notice" ] && output+=$'\n'"$update_notice"
printf '%s' "$output"

if [ "$has_builtin" = true ]; then
    usage_ttl=${STATUSLINE_USAGE_TTL:-300}
else
    usage_ttl=${STATUSLINE_USAGE_TTL:-60}
fi
[[ $usage_ttl =~ ^[0-9]+$ ]] || usage_ttl=60

[ -d "$cache_dir" ] || mkdir -p "$cache_dir"

if [ -n "$render_cache" ]; then
    if (( live_cache_ttl == 0 || live_cache_ttl > 300 )); then
        printf '%s' "$input" > "$render_cache.in"
        write_cache "$render_cache.out" "$now" "$output"
    else
        rm -f "$render_cache.out"
    fi
fi

if (( now - usage_time >= usage_ttl )); then
    printf '%s\n%s' "$now" "$usage_body" > "$usage_cache"
    refresh_usage </dev/null >/dev/null 2>&1 &
fi

if [ "${STATUSLINE_CHECK_UPDATES:-true}" != "false" ] && (( now - release_time >= release_ttl )); then
    printf '%s\n%s' "$now" "$releases_body" > "$release_cache"
    refresh_releases </dev/null >/dev/null 2>&1 &
fi

exit 0
