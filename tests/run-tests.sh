#!/usr/bin/env bash
# End-to-end tests for kimi-code-statusline-bash on macOS: the counterpart of run-tests.ps1.
#
# Installs into throwaway Kimi homes under $TMPDIR, renders the status line the way Kimi
# Code runs it (render.py: sh -c in a process group of its own, a JSON snapshot on stdin),
# and uninstalls again. Your real Kimi home is never touched. Needs jq and Python 3 (for
# render.py and mock_server.py, a local stand-in for the usage API). Written for macOS's
# own bash 3.2.
#
#     bash tests/run-tests.sh [--keep]
#
# --keep keeps the temporary folder for a look afterwards. KSL_TEST_BASH=<path> installs
# with --bash <path>, so the status line runs on that bash (such as Homebrew's bash 5).

KEEP=0
[[ ${1:-} == --keep ]] && KEEP=1
REPO=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ksl-test.XXXXXX") || exit 1
ROOT=$(CDPATH= cd -- "$ROOT" && pwd -P)
ESC=$'\e'
# the Nerd Font icons statusline.sh prints, and · and …
G_MODEL=$'\xf3\xb0\x9a\xa9' G_DIR=$'\xf3\xb0\x89\x8b' G_GIT=$'\xf3\xb0\x8a\xa2' G_QUOTA=$'\xf3\xb0\xaa\x9e'
G_SESSION=$'\xf3\xb1\xa6\xbb' G_CACHE=$'\xef\x87\x80' DOT=$'\xc2\xb7' ELLIPSIS=$'\xe2\x80\xa6'
DAYS=(Sun Mon Tue Wed Thu Fri Sat)
PASSED=0 FAILED=0
TIMES=()
TEST_BASH=${KSL_TEST_BASH:-/bin/bash}
# Kimi Code drops a run still going at 300 ms; CI's shared runners get more room
RENDER_TIMEOUT=300
[[ -n ${CI:-} ]] && RENDER_TIMEOUT=2000
INSTALL_ARGS=()
[[ -n ${KSL_TEST_BASH:-} ]] && INSTALL_ARGS=(--bash "$KSL_TEST_BASH")

if [[ -t 1 ]]; then C_OK=$'\e[32m' C_FAIL=$'\e[31m' C_SKIP=$'\e[33m' C_END=$'\e[0m'; else C_OK= C_FAIL= C_SKIP= C_END=; fi
check() { # $1 = name, $2 = status of the condition (0 = ok), $3 = detail shown on failure
  if [[ $2 == 0 ]]; then PASSED=$(( PASSED + 1 )); printf '  %sok%s    %s\n' "$C_OK" "$C_END" "$1"
  else
    FAILED=$(( FAILED + 1 )); printf '  %sFAIL%s  %s\n' "$C_FAIL" "$C_END" "$1"
    [[ -n ${3:-} ]] && printf '%s\n' "$3" | sed 's/^/        /'
  fi
  return 0
}
skip() { printf '  %sskip%s  %s (%s)\n' "$C_SKIP" "$C_END" "$1" "$2"; }

text_of() { T=; [[ -f $1 ]] && IFS= read -r -d '' T < "$1"; return 0; }   # T = the file, exactly
starts_with() { text_of "$1"; [[ $T == "$2"* ]]; }
file_has() { text_of "$1"; [[ $T =~ $2 ]]; }
file_is() { text_of "$1"; [[ $T == "$2" ]]; }
write_text() { mkdir -p "$(dirname "$1")" && printf '%s' "$2" > "$1"; }
add_text() { printf '%s' "$2" >> "$1"; }
backdate() { touch -t "$(date -v-"$1" +%Y%m%d%H%M.%S)" "$2"; }   # $1 = like 5M or 1H
wait_until() { # command args...: retried for up to 20 s
  local i
  for (( i = 0; i < 100; i++ )); do "$@" && return 0; sleep 0.2; done
  "$@"
}
count_files() { # $1 = folder, $2 = glob -> REPLY
  local f; REPLY=0
  for f in "$1"/$2; do [[ -e $f ]] && REPLY=$(( REPLY + 1 )); done
}
epoch_ms() { # $1 = minutes ago (one decimal at most) -> REPLY = epoch in ms
  local m=${1:-0} i f=0 now
  i=${m%%.*}; [[ $m == *.* ]] && f=${m#*.}
  now=$(date +%s)
  REPLY=$(( (now - (10#$i * 60 + 10#${f:0:1} * 6)) * 1000 ))
}
js() { # $1 -> REPLY = $1 as a JSON string
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  REPLY="\"$s\""
}
quote_sh() { # $1 -> REPLY = $1 as install.sh quotes it for sh
  local q="'"
  if [[ $1 =~ ^[A-Za-z0-9_./+:@%,-]+$ ]]; then REPLY=$1; else REPLY="'${1//$q/$q\\$q$q}'"; fi
}

run_script() { # $1 = script, then its arguments -> CODE, OUT
  OUT=$("$BASH" "$@" 2>&1); CODE=$?
}

tui_command() { # $1 = Kimi home -> REPLY = the [status_line] command in its tui.toml
  local l in=0 s out=
  REPLY=
  [[ -f $1/tui.toml ]] || return 1
  while IFS= read -r l || [[ -n $l ]]; do
    if [[ $l =~ ^\[status_line\] ]]; then in=1; continue; fi
    [[ $l =~ ^\[ ]] && in=0
    if (( in )) && [[ $l =~ ^command\ =\ \"(([^\"\\]|\\.)*)\" ]]; then
      s=${BASH_REMATCH[1]}
      while [[ $s == *\\* ]]; do out+=${s%%\\*}; s=${s#*\\}; out+=${s:0:1}; s=${s:1}; done
      REPLY=$out$s
      return 0
    fi
  done < "$1/tui.toml"
  return 1
}

# One status line run as Kimi Code does it (render.py) -> RAW, TEXT (no colors), CODE, MS.
# Options: mode= cwd= sid= plan= branch= (branch= alone: no branch)
render() {
  local home=$1 mode=yolo cwd=$HOME sid= plan=false branch=main a out json j_cwd j_branch j_sid
  shift
  for a in "$@"; do
    case $a in
      mode=*) mode=${a#*=};; cwd=*) cwd=${a#*=};; sid=*) sid=${a#*=};; plan=*) plan=${a#*=};; branch=*) branch=${a#*=};;
    esac
  done
  tui_command "$home" || { echo "no status line command in $home/tui.toml"; exit 1; }
  local command=$REPLY
  js "$cwd"; j_cwd=$REPLY
  j_branch=null; [[ -n $branch ]] && { js "$branch"; j_branch=$REPLY; }
  j_sid=null; [[ -n $sid ]] && { js "$sid"; j_sid=$REPLY; }
  json='{"model":"K3","cwd":'$j_cwd',"gitBranch":'$j_branch',"permissionMode":"'$mode'","planMode":'$plan
  json+=',"contextUsage":0.1,"contextTokens":1000,"maxContextTokens":10000,"sessionId":'$j_sid',"version":"2.3.2"}'
  out=$(KIMI_CODE_HOME=$home "$PY" -I "$REPO/tests/render.py" "$command" "$json" "$RENDER_TIMEOUT")
  CODE=${out%%$'\t'*}; out=${out#*$'\t'}
  MS=${out%%$'\t'*}; RAW=${out#*$'\t'}
  TEXT=$(printf '%s' "$RAW" | sed $'s/\x1b\\[[0-9;]*m//g')
  TIMES+=("$MS")
}
# Renders about once a second, as Kimi Code does, until the command accepts one (or 20 s
# pass): right after a log grows, a render may still wait for the background scan.
render_until() { # $1 = home, $2 = session id, then a command that looks at RAW / TEXT
  local home=$1 sid=$2 i
  shift 2
  for (( i = 0; i < 28; i++ )); do render "$home" sid="$sid"; "$@" && return 0; sleep 0.7; done
  return 1
}
raw_ends_with() { [[ $RAW == *"$1" ]]; }

# A Kimi home with config.toml and an OAuth token -> REPLY. Options: base=<usage API>,
# noplan (only another provider's API key), tui=<tui.toml> (none without it)
new_home() {
  local h="$ROOT/$1" base=http://127.0.0.1:9/coding/v1 noplan=0 tui= has_tui=0 a cfg
  shift
  for a in "$@"; do
    case $a in base=*) base=${a#*=};; noplan) noplan=1;; tui=*) tui=${a#*=}; has_tui=1;; esac
  done
  mkdir -p "$h"
  if (( noplan )); then
    cfg=$'default_model = "moonshot/kimi-k2"\n\n[providers.moonshot]\ntype = "kimi"\nbase_url = "http://127.0.0.1:9/v1"\napi_key = "sk-test"\n\n[models."moonshot/kimi-k2"]\nprovider = "moonshot"\nmodel = "kimi-k2"\n'
  else
    # (a [secondary_model] with a default_model of its own, before the models: not the one
    # the effort comes from)
    cfg=$'default_model = "kimi-code/k3"\n\n[thinking]\nenabled = true\n\n[secondary_model]\ndefault_model = "kimi-code/k3-mini"\ndefault_effort = "low"\n\n[providers."managed:kimi-code"]\ntype = "kimi"\nbase_url = "'$base$'"\n\n[providers."managed:kimi-code".oauth]\nstorage = "file"\nkey = "oauth/kimi-code"\n\n[models."kimi-code/k3"]\nprovider = "managed:kimi-code"\nmodel = "k3"\ndisplay_name = "K3"\ndefault_effort = "high"\n'
    write_text "$h/credentials/kimi-code.json" '{"access_token":"test-token","refresh_token":"x","expires_at":'$(( $(date +%s) + 3600 ))'}'
  fi
  write_text "$h/config.toml" "$cfg"
  (( has_tui )) && write_text "$h/tui.toml" "$tui"
  REPLY=$h
}

# wire.jsonl records, appended to REC
rec_edit() { # $1 = callId, $2 = old, $3 = new
  local o n; js "$2"; o=$REPLY; js "$3"; n=$REPLY
  REC+='{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Edit","toolCallId":"'$1'","args":{"path":"a.txt","old_string":'$o',"new_string":'$n'}}}'$'\n'
}
rec_write() { # $1 = callId, $2 = content
  js "$2"
  REC+='{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Write","toolCallId":"'$1'","args":{"path":"b.txt","content":'$REPLY'}}}'$'\n'
}
rec_result() { # $1 = callId, $2 = output, $3 = 1 for an error
  local err=; [[ ${3:-0} == 1 ]] && err=',"isError":true'
  js "$2"
  REC+='{"type":"context.append_loop_event","event":{"type":"tool.result","toolCallId":"'$1'","result":{"output":'$REPLY',"note":null'$err'}}}'$'\n'
}
rec_effort() { REC+='{"type":"config.update","modelAlias":"kimi-code/k3","thinkingEffort":"'$1'","time":1}'$'\n'; }
# a turn's boundaries and one model call, as Kimi Code 2.3 logs them
rec_turn_start() {
  epoch_ms 0
  REC+='{"turnId":'$1',"queueItemId":"msg_'$1'","type":"agent.turn.started","time":'$REPLY',"kind":"event"}'$'\n'
  REC+='{"type":"turn.prompt","agentId":"main","promptId":"msg_'$1'","turnId":'$1',"time":'$REPLY'}'$'\n'
}
rec_turn_end() {
  epoch_ms 0
  REC+='{"turnId":'$1',"outcome":"done","type":"agent.turn.ended","time":'$REPLY',"kind":"event"}'$'\n'
  REC+='{"type":"turn.ended","agentId":"main","turnId":'$1',"reason":"completed","time":'$REPLY'}'$'\n'
}
rec_request() { # $1 = model, $2 = minutes ago
  epoch_ms "${2:-0}"
  REC+='{"type":"llm.request","agentId":"main","kind":"loop","provider":"openai","model":"'$1'","modelAlias":"kimi-code/'$1'","time":'$REPLY'}'$'\n'
}
rec_call() { # $1 = minutes ago, $2 = model: a request and its completion
  local m=${2:-k3}
  rec_request "$m" "$1"
  REC+='{"type":"usage.record","agentId":"main","model":"kimi-code/'$m'","usage":{"inputOther":1,"output":2,"inputCacheRead":3,"inputCacheCreation":0},"usageScope":"turn","time":'$REPLY'}'$'\n'
}
rec_switch() { # /model while idle
  epoch_ms 0
  REC+='{"type":"config.update","modelAlias":"kimi-code/'$1'","thinkingEffort":"high","time":'$REPLY'}'$'\n'
}
# Kimi Code's own cached copy of the prompt-cache rules (cache/client-configs)
write_kimi_cache_rules() { # $1 = home, $2 = seconds
  write_text "$1/cache/client-configs/global%3A%2Fclient_configs%3Aestimated_cache_duration.json" \
    '{"version":1,"fetchedAt":1,"config":{"version":1,"config":{"k3":{"min_tokens_to_hint":200000,"cache_duration":'$2'}}}}'
}
k_pattern() { # $1 = in a turn, $2 = model, $3 = alias selected now -> REPLY = an ERE for the K line
  local cur=${3:-kimi-code/$2}
  REPLY=$'(^|\n)K\t[0-9]+\t'$1$'\t'$2$'\tkimi-code/'$2$'\t'$cur$'\t[^\t\n]+\t[^\t\n]+(\n|$)'
}

KIMI_DEFAULT_TUI='# ~/.kimi-code/tui.toml
# Client preferences for kimi-code.
# Agent/runtime settings stay in ~/.kimi-code/config.toml.
theme = "auto" # "auto" | "dark" | "light" | custom theme name
tui_mode = "regular" # "regular" | "fullscreen" ("fullscreen" is experimental)
[editor]
command = "" # Empty uses $VISUAL / $EDITOR
[notifications]
enabled = true # true | false
notification_condition = "unfocused" # "unfocused" | "always"
[upgrade]
auto_install = true # true | false

# [status_line]
# Pick and order the built-in footer slots: mode, goal, model, tasks, cwd, git, tips
# Or render your own: a command whose first stdout line replaces footer line 1.
# It receives a JSON snapshot (model, cwd, git, usage, mode) on stdin.
# command = "~/.kimi-code/statusline.sh"

'

SERVER=
cleanup() {
  [[ -n $SERVER ]] && kill "$SERVER" 2>/dev/null
  if (( KEEP )); then echo "kept $ROOT"
  else
    local i   # background workers may still hold a cache file for a moment
    for (( i = 0; i < 10; i++ )); do rm -rf "$ROOT" 2>/dev/null && break; sleep 0.5; done
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------- prerequisites ---
PY=$(command -v python3 2>/dev/null)
[[ -n $PY && $("$PY" -c 'print(1)' 2>/dev/null) == 1 ]] || { echo 'These tests need Python 3 (python3).'; exit 1; }
JQ=$(command -v jq 2>/dev/null)
[[ -n $JQ ]] || { echo 'These tests need jq.'; exit 1; }
echo "bash for the status line: $TEST_BASH ($("$TEST_BASH" -c 'echo $BASH_VERSION'))"

# ---------------------------------------------------------------------- mock server ---
mkdir -p "$ROOT/files"
cp "$REPO/statusline.sh" "$ROOT/files/"
"$PY" -I "$REPO/tests/mock_server.py" "$ROOT/port" "$ROOT/files" >/dev/null 2>&1 &
SERVER=$!
disown "$SERVER" 2>/dev/null   # (no "Terminated" notice when cleanup stops it)
wait_until test -f "$ROOT/port" || { echo 'mock server did not start'; exit 1; }
PORT=$(< "$ROOT/port")
BASE_URL="http://127.0.0.1:$PORT/coding/v1"

# -------------------------------------------------------------------------- install ---
echo install
# a space, & ( ) and ' in the path: install.sh must quote it for sh
new_home "kimi home (A) & co's" base="$BASE_URL" tui="$KIMI_DEFAULT_TUI"; A=$REPLY
write_kimi_cache_rules "$A" 1800   # used only if the mock server's rules don't come
run_script "$REPO/install.sh" --kimi-home "$A" "${INSTALL_ARGS[@]}"
[[ $CODE == 0 ]]; check 'install.sh succeeds' $? "$OUT"
app="$A/statusline-bash"
cmp -s "$app/statusline.sh" "$REPO/statusline.sh" && [[ -x $app/statusline.sh ]]; check 'statusline.sh installed as it is, executable' $?
IFS= read -r jq_rec < "$app/jq-path.txt"
[[ -n $jq_rec && -x $jq_rec ]]; check 'jq-path.txt records jq' $? "$jq_rec"
tui_command "$A"; cmd=$REPLY
quote_sh "$TEST_BASH"; want=$REPLY; quote_sh "$app/statusline.sh"; want+=" $REPLY"
[[ $cmd == "$want" ]]; check 'tui.toml command: bash and the script, each quoted for sh' $? "command = $cmd"
eval "set -- $cmd"
[[ $# == 2 && $1 == "$TEST_BASH" && $2 == "$app/statusline.sh" ]]; check '... which sh reads back as the two paths' $? "$*"
text_of "$A/tui.toml"; tui=$T
d=$KIMI_DEFAULT_TUI; while [[ $d == *$'\n' ]]; do d=${d%$'\n'}; done
[[ $tui == "$d"* ]]; check 'tui.toml keeps everything else' $? "$tui"
count_files "$A" 'tui.toml.bak-*'; [[ $REPLY == 1 ]]; check 'tui.toml backed up' $?
text_of "$app/install.json"; info=$T
[[ $info =~ \"previousLine\":\ null && $info =~ \"createdTable\":\ true ]]; check 'install.json records no previous line (as null)' $? "$info"
[[ $("$JQ" -r .command "$app/install.json") == "$cmd" ]]; check '... and the command, as valid JSON' $? "$info"

run_script "$REPO/install.sh" --kimi-home "$A" "${INSTALL_ARGS[@]}"
[[ $CODE == 0 ]]; check 'running install.sh again succeeds' $? "$OUT"
count_files "$A" 'tui.toml.bak-*'; n_bak=$REPLY; count_files "$app" '*.bak-*'
file_is "$A/tui.toml" "$tui" && [[ $n_bak == 1 && $REPLY == 0 ]]; check '... and changes nothing' $?

# ---------------------------------------------------------------------------- render ---
echo render
for c in 'manual|Always Ask|92' 'yolo|Ask When Needed|93' 'auto|Never Ask|91' 'weird|weird|97'; do
  IFS='|' read -r mode label color <<< "$c"
  render "$A" mode="$mode"
  [[ $CODE == 0 && $RAW == "$ESC[1;${color}m$label$ESC[0m"* ]]; check "permission mode $mode -> $label" $? "$TEXT"
done
render "$A" mode=yolo plan=true
[[ $TEXT == 'Ask When Needed plan | '* ]]; check 'plan mode badge' $? "$TEXT"
render "$A" cwd="$HOME/Desktop/proj"
[[ $TEXT == *"$G_MODEL K3 $DOT high"* ]]; check "model and config effort (the default model's, not [secondary_model]'s)" $? "$TEXT"
[[ $TEXT == *"$G_DIR ~/Desktop/proj"* ]]; check 'home folder shown as ~' $? "$TEXT"
[[ $TEXT == *"$G_GIT main"* ]]; check 'git branch' $? "$TEXT"
render "$A" cwd=/a/b/c/d/e branch=
[[ $TEXT == *"$G_DIR $ELLIPSIS/c/d/e"* ]]; check 'long path keeps the last 3 folders' $? "$TEXT"
[[ $TEXT != *"$G_GIT"* ]]; check 'no branch, no git part' $? "$TEXT"

# --------------------------------------------------------------------------- session ---
echo session
sid=session_0123456789abcdef
sdir="$A/sessions/wd_test_000000000000/$sid"
created=$(( ($(date +%s) - 83 * 60 - 20) * 1000 ))
write_text "$sdir/state.json" '{"agents":{},"createdAt":'$created',"title":"t","workDir":"/x"}'
main="$sdir/agents/main/wire.jsonl"
REC='{"type":"metadata","protocol_version":"1.5","created_at":'$created'}'$'\n'
rec_effort max
rec_edit c1 $'a\nb\nc' $'a\nB\nc\nd'; rec_result c1 'Replaced 1 occurrence'      # +2 -1
rec_write c2 $'x\ny\nz\n'; rec_result c2 'Wrote b.txt'                             # +3
rec_edit c3 p q; rec_result c3 'old_string not found' 1                            # failed: 0
rec_edit c4 foo bar; rec_result c4 'Replaced 3 occurrences'                        # +3 -3
write_text "$main" "$REC"
REC=; rec_effort low; rec_edit s1 q $'r\ns'; rec_result s1 'Replaced 1 occurrence' # +2 -1
write_text "$sdir/agents/sub1/wire.jsonl" "$REC"
state="$A/cache/statusline/$sid.state"
render "$A" sid=$sid
[[ $TEXT == *"$G_SESSION 1h2"[34]m* ]]; check 'elapsed time' $? "$TEXT"
wait_until starts_with "$state" $'10\t5\tmax\n'; check 'background scan counts main and sub-agent edits' $? "$(cat "$state" 2>&1)"
render "$A" sid=$sid
[[ $TEXT == *" 1h2"[34]"m +10/-5" ]]; check 'changed lines +10/-5' $? "$TEXT"
[[ $TEXT == *"K3 $DOT max"* ]]; check 'thinking effort from the session (main agent only)' $? "$TEXT"

REC=; rec_edit c5 1 2; rec_result c5 'Replaced 1 occurrence'
rec_edit c6 m n; add_text "$main" "${REC%$'\n'}"    # (c6: a record still being written)
render "$A" sid=$sid
wait_until starts_with "$state" $'11\t6\tmax\n'; check 'appended records are added; a half-written one waits' $? "$(cat "$state")"
REC=$'\n'; rec_result c6 'Replaced 1 occurrence'; add_text "$main" "$REC"
render "$A" sid=$sid
wait_until starts_with "$state" $'12\t7\tmax\n'; check '... and is counted once complete' $? "$(cat "$state")"
render "$A" sid=$sid
[[ $TEXT == *'+12/-7' ]]; check 'changed lines +12/-7' $? "$TEXT"

# A long run of emoji (jq miscounts its bytes) must not push the read position into the
# next record.
emoji=$'\xf0\x9f\x98\x80'; printf -v pad '%3000s' ''; emoji=${pad// /$emoji}
REC='{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Write","toolCallId":"c7","args":{"path":"e.txt","content":"'$emoji'\n"}}}'$'\n'
rec_result c7 'Wrote e.txt'; add_text "$main" "$REC"                                # +1
render "$A" sid=$sid
wait_until starts_with "$state" $'13\t7\tmax\n' >/dev/null
REC=; rec_edit c8 g h; rec_result c8 'Replaced 1 occurrence'; add_text "$main" "$REC"  # +1 -1
render "$A" sid=$sid
wait_until starts_with "$state" $'14\t8\tmax\n'; check 'a record after a long run of emoji is still read' $? "$(head -1 "$state")"

# a session outside sessions/, found through session_index.jsonl
osid=session_elsewhere
odir="$ROOT/elsewhere/$osid"
epoch_ms 5; write_text "$odir/state.json" '{"createdAt":'$REPLY'}'
js "$odir"; write_text "$A/session_index.jsonl" '{"sessionId":"'$osid'","sessionDir":'$REPLY',"workDir":"/x"}'$'\n'
render "$A" sid=$osid
[[ $TEXT == *"$G_SESSION 5m" ]]; check 'a session found through session_index.jsonl' $? "$TEXT"
qsid=session_quote
qdir="$ROOT/else\"where/$qsid"
epoch_ms 7; write_text "$qdir/state.json" '{"createdAt":'$REPLY'}'
js "$qdir"; add_text "$A/session_index.jsonl" '{"sessionId":"'$qsid'","sessionDir":'$REPLY',"workDir":"/x"}'$'\n'
render "$A" sid=$qsid
[[ $TEXT == *"$G_SESSION 7m" ]]; check '... also with a " in its path' $? "$TEXT"

# a sub-agent's log that is gone during a scan and then back: not counted twice
sub="$sdir/agents/sub1/wire.jsonl"
mv "$sub" "$ROOT/sub1.wire.jsonl"
REC=; rec_edit c9 x y; rec_result c9 'Replaced 1 occurrence'; add_text "$main" "$REC"   # +1 -1
render "$A" sid=$sid
wait_until starts_with "$state" $'15\t9\tmax\n'; r=$?
mv "$ROOT/sub1.wire.jsonl" "$sub"
REC=; rec_edit c10 x y; rec_result c10 'Replaced 1 occurrence'; add_text "$main" "$REC"  # +1 -1
render "$A" sid=$sid
wait_until file_has "$state" $'^(16\t10|18\t11)\t' >/dev/null   # (18/11: sub1 counted again)
(( r == 0 )) && starts_with "$state" $'16\t10\tmax\n'; check "a log that was gone during a scan isn't counted again when it's back" $? "$(head -1 "$state")"

# ----------------------------------------------------------------------------- quota ---
echo quota
quota="$A/cache/statusline/quota"
render "$A"
wait_until file_has "$quota" $'\t92\tq\t5\t[0-9]+\t52\t[0-9]+\t-\n'; check 'quota fetched in the background' $? "$(cat "$quota")"
render "$A"
IFS=$'\t' read -r -a f < "$quota"
now=$(date +%s)
left=$(( (f[5] - now + 59) / 60 ))
want_left=()
for t in "$left" $(( left + 1 )); do   # (rendered a moment earlier)
  if (( t >= 60 )); then want_left+=("$(printf '%dh%02dm' $(( t / 60 )) $(( t % 60 )))"); else want_left+=("${t}m"); fi
done
w=$(date -r "${f[7]}" '+%w %H:%M')
want="$G_QUOTA 5h 5% $DOT <left> $DOT 7d 52% $DOT ${DAYS[${w%% *}]} ${w#* }"
[[ $TEXT == *"${want/<left>/${want_left[0]}}"* || $TEXT == *"${want/<left>/${want_left[1]}}"* ]]
check "quota part: time left in 5 hours, the week's reset in local time" $? "$TEXT / want $want, <left> = ${want_left[*]}"
[[ $RAW == *"$ESC[92m$G_QUOTA 5h"* ]]; check 'quota colored green under 60%' $? "$RAW"

# a quota cache written by v0.1.0 (text): refetched at once, "…" until then
write_text "$quota" "$(( now + 300 ))"$'\t'"$now"$'\t92\t'"5h 5% (rst 00:34) $DOT 7d 52% (rst 10/25 23:34)"$'\n'
render "$A"
[[ $TEXT == *"$G_QUOTA $ELLIPSIS"* ]]; check 'quota cache in the old format: not shown as numbers' $? "$TEXT"
wait_until file_has "$quota" $'\tq\t5\t'; check '... and refetched right away' $? "$(cat "$quota")"

# the week only: no 5-hour numbers, and the week's not shifted into their place
new_home 'weekly only' base="http://127.0.0.1:$PORT/weekly/coding/v1" tui=; Wk=$REPLY
run_script "$REPO/install.sh" --kimi-home "$Wk" "${INSTALL_ARGS[@]}"
wait_until file_has "$Wk/cache/statusline/quota" $'\tq\t-\t-\t52\t[0-9]+\t-\n'; check 'a report with the week only' $? "$(cat "$Wk/cache/statusline/quota")"
render "$Wk"
re="$G_QUOTA 7d 52% $DOT [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}"
[[ $TEXT =~ $re && $TEXT != *5h* ]]; check '... shows the week only' $? "$TEXT"
# a 5-hour window that resets this very second: fetched again 5 s later
new_home 'reset now' base="http://127.0.0.1:$PORT/now/coding/v1" tui=; Sn=$REPLY
run_script "$REPO/install.sh" --kimi-home "$Sn" "${INSTALL_ARGS[@]}"
wait_until file_has "$Sn/cache/statusline/quota" $'\tq\t5\t' >/dev/null
IFS=$'\t' read -r -a f < "$Sn/cache/statusline/quota"
[[ ${#f[@]} -ge 6 && ${f[0]} == $(( f[5] + 5 )) ]]; check 'a window that resets before the next fetch: fetched again 5 s after the reset' $? "${f[*]}"

# also: a jq in a folder with a non-ASCII name (its path goes into jq-path.txt)
jq_copy=
for j in "$JQ" /usr/bin/jq; do
  [[ -x $j ]] || continue
  dest="$ROOT/jq "$'\xe4\xb8\xad\xe6\x96\x87'"$PASSED/jq"
  mkdir -p "$(dirname "$dest")" && cp "$j" "$dest"
  [[ $("$dest" -n 1 2>/dev/null) == 1 ]] && { jq_copy=$dest; break; }
done
new_home 'no plan' noplan tui=; N=$REPLY
n_args=(--kimi-home "$N" "${INSTALL_ARGS[@]}")
[[ -n $jq_copy ]] && n_args+=(--jq "$jq_copy")
run_script "$REPO/install.sh" "${n_args[@]}"
tui_command "$N"
[[ $CODE == 0 && -n $REPLY ]]; check 'install into an empty tui.toml' $? "$OUT"
if [[ -n $jq_copy ]]; then
  IFS= read -r l < "$N/statusline-bash/jq-path.txt"
  [[ $l == "$jq_copy" ]]; check 'non-ASCII jq folder: jq-path.txt holds the path' $? "$l"
  nsid=session_n
  epoch_ms 0; write_text "$N/sessions/wd_n/$nsid/state.json" '{"createdAt":'$REPLY'}'
  REC=; rec_edit n1 a b; rec_result n1 'Replaced 1 occurrence'; write_text "$N/sessions/wd_n/$nsid/agents/main/wire.jsonl" "$REC"
  render "$N" sid=$nsid
  wait_until starts_with "$N/cache/statusline/$nsid.state" $'1\t1\t'; check '... and that jq does the counting' $? "$(cat "$N/cache/statusline/$nsid.state" 2>&1)"
else skip 'non-ASCII jq folder' 'no jq that runs from a copy'; fi
render "$N"
wait_until file_has "$N/cache/statusline/quota" $'\t-\n?$'; check 'no Kimi Code plan: quota marked as none' $? "$(cat "$N/cache/statusline/quota")"
render "$N"
[[ $CODE == 0 && -n $TEXT && $TEXT != *"$G_QUOTA"* ]]; check '... and not shown' $? "$TEXT"
[[ ! -e $N/cache/statusline/cache-rules ]]; check '... nor the prompt-cache rules fetched' $?

# ---------------------------------------------------------------------- prompt cache ---
echo 'prompt cache'
rules="$A/cache/statusline/cache-rules"
wait_until file_has "$rules" $'(^|\n)k3\t1800(\n|$)'; check 'cache rules fetched with the quota' $? "$(cat "$rules")"
file_has "$rules" $'^[1-9][0-9]*\n' && file_has "$rules" $'(^|\n)kimi-for-coding\t3600(\n|$)'; check '... from the server' $? "$(cat "$rules")"
csid=session_cache
csdir="$A/sessions/wd_test_000000000000/$csid"
epoch_ms 30; write_text "$csdir/state.json" '{"createdAt":'$REPLY'}'
cmain="$csdir/agents/main/wire.jsonl"
cstate="$A/cache/statusline/$csid.state"
REC='{"type":"metadata","protocol_version":"1.5","created_at":'$REPLY'}'$'\n'
rec_turn_start 0; rec_call 10.2; rec_turn_end 0
write_text "$cmain" "$REC"
cache_end() { REPLY="$ESC[${2:-34}m$G_CACHE $1$ESC[0m"; }   # $1 = text, $2 = color
render "$A" sid=$csid
k_pattern 0 k3; wait_until file_has "$cstate" "$REPLY"; check 'the scan records the last model call, the turn state and the model' $? "$(cat "$cstate")"
cache_end 20m; want=$REPLY
render_until "$A" $csid raw_ends_with "$want"; check 'between turns: minutes left on the cache, in blue, at the end' $? "$TEXT"

REC=; rec_switch kimi-for-coding; add_text "$cmain" "$REC"
cache_end cold 33; want=$REPLY
render_until "$A" $csid raw_ends_with "$want"; check 'another model selected (/model): "cold"' $? "$TEXT / $(cat "$cstate")"
REC=; rec_switch k3; add_text "$cmain" "$REC"
cache_end 20m; want=$REPLY
render_until "$A" $csid raw_ends_with "$want"; check '... and back to the first model: the countdown again' $? "$TEXT / $(cat "$cstate")"

REC=; rec_turn_start 1; add_text "$cmain" "$REC"
render "$A" sid=$csid
[[ $TEXT != *"$G_CACHE"* ]]; check 'hidden as soon as the log grows (a turn is likely running)' $? "$TEXT"
k_pattern 1 k3; wait_until file_has "$cstate" "$REPLY" >/dev/null
render "$A" sid=$csid
file_has "$cstate" $'(^|\n)K\t[0-9]+\t1\t' && [[ $TEXT != *"$G_CACHE"* ]]; check '... and while the turn runs' $? "$TEXT / $(cat "$cstate")"
REC=; rec_request kimi-for-coding; rec_turn_end 1; add_text "$cmain" "$REC"   # stopped before it completed
cache_end cold 33; want=$REPLY
render_until "$A" $csid raw_ends_with "$want"; r=$?
k_pattern 0 k3 kimi-code/kimi-for-coding
(( r == 0 )) && file_has "$cstate" "$REPLY"; check 'a request to another model that never completed: "cold", not that model'"'"'s time' $? "$TEXT / $(cat "$cstate")"

REC=; rec_turn_start 2; rec_call 28; rec_turn_end 2; add_text "$cmain" "$REC"   # (an older call, to get near the end)
cache_end 2m 33; want=$REPLY
render_until "$A" $csid raw_ends_with "$want"; check 'yellow in the last 5 minutes' $? "$TEXT / $(cat "$cstate")"
# a duration with a leading zero (bash would read 03600 as octal 1920): not used
text_of "$rules"; rules_text=$T
write_text "$rules" "${rules_text/$'\nk3\t1800'/$'\nk3\t03600'}"
render "$A" sid=$csid
[[ $CODE == 0 && $TEXT != *"$G_CACHE"* ]]; check 'a cache rule with a leading zero is ignored' $? "$TEXT"
write_text "$rules" "$rules_text"

REC=; rec_turn_start 3; rec_call 31; add_text "$cmain" "$REC"
render "$A" sid=$csid
k_pattern 1 k3; wait_until file_has "$cstate" "$REPLY" >/dev/null
render "$A" sid=$csid
cache_end cold 33; raw_ends_with "$REPLY"; check 'expired: "cold", even during a turn' $? "$TEXT"

REC=; rec_call 1 unknown-model; rec_turn_end 3; add_text "$cmain" "$REC"
render "$A" sid=$csid
k_pattern 0 unknown-model; wait_until file_has "$cstate" "$REPLY" >/dev/null
render "$A" sid=$csid
[[ $CODE == 0 && -n $TEXT && $TEXT != *"$G_CACHE"* ]]; check 'no rule for the model: no countdown' $? "$TEXT"

# a state written by v0.1.0 (no K line, everything already read): the logs are read again
size=$(stat -f %z "$cmain")
write_text "$cstate" $'3\t4\tmax\nF\t'"$cmain"$'\t'"$size"$'\n'
backdate 5M "$cstate"
render "$A" sid=$csid
k_pattern 0 unknown-model; kp=$REPLY
v010() { starts_with "$cstate" $'0\t0\thigh\n' && file_has "$cstate" "$kp"; }
wait_until v010; check 'a state from v0.1.0 is rebuilt from the whole log' $? "$(cat "$cstate")"
write_text "$cstate" $'0\t0\thigh\nK\t1\t0\tk3\nF\t'"$cmain"$'\t'"$size"$'\n'
backdate 5M "$cstate"
render "$A" sid=$csid
wait_until file_has "$cstate" "$kp"; check '... and so is one with a K line it cannot read' $? "$(cat "$cstate")"

# ------------------------------------------------------------------------- uninstall ---
echo uninstall
sleep 1   # (let the last background scan finish)
run_script "$REPO/uninstall.sh" --kimi-home "$A"
[[ $CODE == 0 ]]; check 'uninstall.sh succeeds' $? "$OUT"
file_is "$A/tui.toml" "$KIMI_DEFAULT_TUI"; check 'tui.toml is back to the original' $? "$(cat "$A/tui.toml")"
[[ ! -e $app && ! -e $A/cache/statusline ]]; check 'installed files and cache removed' $? "$(ls -A "$app" "$A/cache/statusline" 2>&1)"
count_files "$A" 'tui.toml.bak-*'; [[ $REPLY == 2 ]] && file_is "$(ls "$A"/tui.toml.bak-* | head -1)" "$KIMI_DEFAULT_TUI"
check "tui.toml's backups: the original and the installed one" $? "$(ls "$A")"

# ------------------------------------------------------------- someone else's command ---
echo 'another status line'
other_tui=$'theme = "dark"\n\n[status_line]\nitems = ["mode", "model"]\ncommand = "/tools/other.sh"\n\n[upgrade]\nauto_install = true\n'
new_home kimiB tui="$other_tui"; B=$REPLY
run_script "$REPO/install.sh" --kimi-home "$B" "${INSTALL_ARGS[@]}"
[[ $CODE != 0 && $OUT == *'another status line command'* ]]; check 'install.sh refuses to replace it' $? "$OUT"
file_is "$B/tui.toml" "$other_tui"; check '... and leaves tui.toml alone' $?
run_script "$REPO/install.sh" --kimi-home "$B" --force "${INSTALL_ARGS[@]}"
tui_command "$B"
[[ $CODE == 0 && $REPLY == *statusline-bash/statusline.sh* ]]; check 'install.sh --force replaces it' $? "$OUT"
file_has "$B/tui.toml" $'\\[status_line]\nitems = \\["mode", "model"]\ncommand = "[^"]+statusline\\.sh\'?"\n\n\\[upgrade]'; check '... in place' $? "$(cat "$B/tui.toml")"
run_script "$REPO/uninstall.sh" --kimi-home "$B"
[[ $CODE == 0 ]] && file_is "$B/tui.toml" "$other_tui"; check 'uninstall.sh puts the old command back' $? "$(cat "$B/tui.toml")"

# --------------------------------------------------------------- other tui.toml forms ---
echo 'tui.toml forms'
i=0
for t in $'[status_line]\n"command" = "/tools/other.sh"\n' \
         $'["status_line"]\ncommand = "/tools/other.sh"\n' \
         $'[status_line]\ncommand = "echo /tools/statusline-bash/statusline.sh"\n'; do
  names=('quoted key' 'quoted table name' 'our path inside another command')
  new_home "form $i" tui="$t"; h=$REPLY
  write_text "$h/statusline-bash/statusline.sh" $'custom\n'
  run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
  [[ $CODE != 0 && $OUT == *'another status line command'* ]]; check "${names[i]}: seen as another tool's command" $? "$OUT"
  file_is "$h/tui.toml" "$t" && file_is "$h/statusline-bash/statusline.sh" $'custom\n' && [[ ! -e $h/statusline-bash/install.json ]]
  check '... and nothing is written' $?
  i=$(( i + 1 ))
done
zh=$'\xe4\xb8\xad'
i=0
for t in "command = \"/tools/$zh.sh\"|/tools/$zh.sh" \
         'command = "/tools/\u4e2d.sh" # note|'"/tools/$zh.sh" \
         "command = '/tools\\other.sh'|/tools\\other.sh"; do
  names=('non-ASCII command' 'escaped command' 'literal string')
  line=${t%|*} value=${t##*|}
  tui=$'theme = "dark"\n\n[status_line]\n'"$line"$'\n'
  new_home "round $i" tui="$tui"; h=$REPLY
  run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
  pc=$("$JQ" -r .previousCommand "$h/statusline-bash/install.json" 2>&1)
  pl=$("$JQ" -r .previousLine "$h/statusline-bash/install.json" 2>&1)
  [[ $CODE == 0 && $pc == "$value" && $pl == "$line" ]]; check "${names[i]}: --force records it" $? "$OUT / $pc / $pl"
  run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
  [[ $CODE == 0 && $("$JQ" -r .previousLine "$h/statusline-bash/install.json") == "$line" ]]; check '... a second install keeps the record' $? "$OUT"
  run_script "$REPO/uninstall.sh" --kimi-home "$h"
  [[ $CODE == 0 ]] && file_is "$h/tui.toml" "$tui"; check '... and uninstall restores it byte for byte' $? "$(cat "$h/tui.toml")"
  i=$(( i + 1 ))
done
tui=$'[status_line] # my choice\n# items = ["mode"]\n\n[upgrade]\nauto_install = true\n'
new_home 'table with comments' tui="$tui"; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
[[ $CODE == 0 ]] && file_has "$h/tui.toml" $'^\\[status_line] # my choice\ncommand = "[^"]+"\n# items'
check 'a table with only comments gets the command under its header' $? "$(cat "$h/tui.toml")"
run_script "$REPO/uninstall.sh" --kimi-home "$h"
file_is "$h/tui.toml" "$tui"; check '... and uninstall keeps the table and its comments' $? "$(cat "$h/tui.toml")"
new_home single-quoted-ours tui=; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
text_of "$h/tui.toml"; [[ $T =~ command\ =\ \"([^\"]+)\" ]] && write_text "$h/tui.toml" "${T/\"${BASH_REMATCH[1]}\"/'${BASH_REMATCH[1]}'}"
run_script "$REPO/uninstall.sh" --kimi-home "$h"
[[ $CODE == 0 ]] && ! grep -q command "$h/tui.toml"; check 'uninstall recognizes its command in a literal string' $? "$(cat "$h/tui.toml")"
# line endings: lines added end like the line before them, no final newline is added, and
# install + uninstall give back every byte
t=$'a = 1\r\nb = 2\n'
new_home 'endings new table' tui="$t"; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
starts_with "$h/tui.toml" $'a = 1\r\nb = 2\n\n[status_line]\ncommand = ' && file_has "$h/tui.toml" $'[^\r]\n$'; r=$?
run_script "$REPO/uninstall.sh" --kimi-home "$h"
(( r == 0 )) && file_is "$h/tui.toml" "$t"; check 'mixed line endings, a new table: it follows the last line, and uninstall gives back every byte' $? "$(od -c "$h/tui.toml" | head -5)"
t=$'[status_line]\r\nitems = []\n'
new_home 'endings in table' tui="$t"; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
file_has "$h/tui.toml" $'^\\[status_line]\r\ncommand = "[^"]+"\r\nitems = \\[]\n$'; r=$?
run_script "$REPO/uninstall.sh" --kimi-home "$h"
(( r == 0 )) && file_is "$h/tui.toml" "$t"; check '... the command added under a CRLF header ends in CRLF, and goes again' $? "$(od -c "$h/tui.toml" | head -5)"
t='theme = "dark"'
new_home 'endings none at the end' tui="$t"; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
file_has "$h/tui.toml" $'^theme = "dark"\n\n\\[status_line]\ncommand = "[^"]+"$'; r=$?
run_script "$REPO/uninstall.sh" --kimi-home "$h"
(( r == 0 )) && file_is "$h/tui.toml" "$t"; check '... no newline at the end: none added, and every byte given back' $? "$(od -c "$h/tui.toml" | head -5)"
# backups made in the same second (an uninstall right after the install) keep apart
new_home 'same second' tui="$KIMI_DEFAULT_TUI"; h=$REPLY
now=$(date +%s)
for (( s = 0; s < 30; s++ )); do printf taken > "$h/tui.toml.bak-$(date -r $(( now + s )) +%Y%m%d-%H%M%S)"; done
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"; r=$CODE
run_script "$REPO/uninstall.sh" --kimi-home "$h"
taken=0 orig=0 n=0
for f in "$h"/tui.toml.bak-*; do
  n=$(( n + 1 )); text_of "$f"
  [[ $T == taken ]] && taken=$(( taken + 1 )); [[ $T == "$KIMI_DEFAULT_TUI" ]] && orig=$(( orig + 1 ))
done
[[ $r == 0 && $CODE == 0 && $n == 32 && $taken == 30 && $orig == 1 ]]; check 'backups never overwrite each other' $? "$n backups, $taken taken, $orig original / $(ls "$h")"
tui=$'[status_line]\ncommand = "/tools/other.sh" # was = "/bin/bash /x/statusline-bash/statusline.sh"\n'
new_home 'comment mentions us' tui="$tui"; h=$REPLY
run_script "$REPO/uninstall.sh" --kimi-home "$h"
[[ $CODE == 0 ]] && file_is "$h/tui.toml" "$tui"; check "uninstall leaves another tool's command alone, whatever its comment says" $? "$(cat "$h/tui.toml")"
tui=$'[status_line]\ncommand = "/tools/other.sh"\n'
new_home 'dotted key' tui=$'status_line.command = "/tools/other.sh"\n'; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
[[ $CODE != 0 && $OUT == *'does not edit'* ]] && file_is "$h/tui.toml" $'status_line.command = "/tools/other.sh"\n'
check 'a dotted status_line key: not edited, even with --force' $? "$OUT"

# -------------------------------------------------------------------------- failures ---
echo 'installer failures'
tui=$'theme = "dark"\n\n[status_line]\ncommand = "/tools/other.sh"\n'
# a tui.toml that can't be read must not pass for an empty one and be replaced
new_home unreadable tui="$tui"; h=$REPLY
chmod 200 "$h/tui.toml"
run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
chmod 600 "$h/tui.toml"
count_files "$h" 'tui.toml.bak-*'
[[ $CODE != 0 && $OUT == *'cannot read'* && $REPLY == 0 ]] && file_is "$h/tui.toml" "$tui"
check 'an unreadable tui.toml: an error, and left as it was' $? "$OUT"
# install.json first: if it can't be written, tui.toml stays, and the command it would
# replace is not lost
new_home 'no record' tui="$tui"; h=$REPLY
mkdir -p "$h/statusline-bash/install.json.tmp"   # (a folder: install.json can't be written)
run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
[[ $CODE != 0 && $OUT == *'cannot write'* ]] && file_is "$h/tui.toml" "$tui"
check "install.json can't be written: tui.toml is left as it was" $? "$OUT"
rmdir "$h/statusline-bash/install.json.tmp"
run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
[[ $CODE == 0 && $("$JQ" -r .previousLine "$h/statusline-bash/install.json") == 'command = "/tools/other.sh"' ]]
check '... and the next install still records the command it replaces' $? "$OUT"
# a key spelled with escapes would be missed, and a second command added: refused
t=$'[status_line]\n"com\\u006dand" = "/tools/other.sh"\n'
new_home 'escaped key' tui="$t"; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
[[ $CODE != 0 && $OUT == *escapes* ]] && file_is "$h/tui.toml" "$t"; check 'a [status_line] key with escapes: refused, nothing written' $? "$OUT"
i=0
for t in $'"status\\u005fline".command = "/tools/other.sh"\n' $'"status\\u005fline" = { command = "/tools/other.sh" }\n'; do
  new_home "escaped top $i" tui="$t"; h=$REPLY
  run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
  [[ $CODE != 0 && $OUT == *escapes* ]] && file_is "$h/tui.toml" "$t"; r=$?
  (( i )) && check '... and a top-level one, as a dotted key or an inline table' $(( r + rr )) "$OUT"
  rr=$r i=$(( i + 1 ))
done
# an upgrade to another bash that can't write tui.toml: the record keeps telling of the
# command tui.toml runs, so uninstall still puts the replaced one back
new_home 'failed upgrade' tui="$tui"; h=$REPLY
ln -s "$TEST_BASH" "$ROOT/bash-one"; ln -s "$TEST_BASH" "$ROOT/bash-two"
run_script "$REPO/install.sh" --kimi-home "$h" --force --bash "$ROOT/bash-one" --jq "$JQ"
text_of "$h/tui.toml"; installed=$T
chmod 444 "$h/tui.toml"
run_script "$REPO/install.sh" --kimi-home "$h" --bash "$ROOT/bash-two" --jq "$JQ"
chmod 644 "$h/tui.toml"
[[ $CODE != 0 && $("$JQ" -r .command "$h/statusline-bash/install.json") == "$ROOT/bash-one "* ]] && file_is "$h/tui.toml" "$installed"
check "an upgrade that can't write tui.toml: an error, nothing changed" $? "$OUT"
run_script "$REPO/uninstall.sh" --kimi-home "$h"
[[ $CODE == 0 ]] && file_is "$h/tui.toml" "$tui"; check '... and uninstall still puts the replaced command back' $? "$(cat "$h/tui.toml")"
# files it replaces keep their permissions
new_home 'kept mode' tui=; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
chmod 600 "$h/statusline-bash/install.json"
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
[[ $CODE == 0 && $(stat -f %Lp "$h/statusline-bash/install.json") == 600 ]]; check 'install.json keeps its permissions when rewritten' $? "$(ls -l "$h/statusline-bash")"
# a command with a control character (\b) in it: install.json must stay valid JSON
t=$'[status_line]\ncommand = "echo \\bhello"\n'
new_home 'control escape' tui="$t"; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" --force "${INSTALL_ARGS[@]}"
pc=$("$JQ" -r .previousCommand "$h/statusline-bash/install.json" 2>&1)
[[ $CODE == 0 && $pc == $'echo \bhello' ]]; check 'a replaced command with a control character: install.json stays valid JSON' $? "$OUT / $pc"
run_script "$REPO/uninstall.sh" --kimi-home "$h"
[[ $CODE == 0 ]] && file_is "$h/tui.toml" "$t"; check '... and uninstall puts it back' $? "$(cat "$h/tui.toml")"
# uninstall that can't delete the installed files says so
new_home 'locked app' tui=; h=$REPLY
run_script "$REPO/install.sh" --kimi-home "$h" "${INSTALL_ARGS[@]}"
chmod 555 "$h/statusline-bash"
run_script "$REPO/uninstall.sh" --kimi-home "$h"
chmod 755 "$h/statusline-bash"
[[ $CODE != 0 && $OUT == *'could not delete'* ]]; check "uninstall.sh: files it could not delete are an error, not a success" $? "$OUT"
OUT=$("$BASH" -s -- --help < "$REPO/install.sh" 2>&1)
[[ $OUT == *--kimi-home* ]]; r=$?
OUT+=$("$BASH" -s -- --help < "$REPO/uninstall.sh" 2>&1)
(( r == 0 )) && [[ $OUT == *'Options: --kimi-home'* ]]; check 'piped into bash, --help still lists the options' $? "$OUT"

# ------------------------------------------------------------------------- hardening ---
echo hardening
new_home kimiD tui=; D=$REPLY   # no usage API: every fetch fails
write_kimi_cache_rules "$D" 1200
run_script "$REPO/install.sh" --kimi-home "$D" "${INSTALL_ARGS[@]}"
dsid=session_d
dsdir="$D/sessions/wd_d/$dsid"
epoch_ms 0; write_text "$dsdir/state.json" '{"createdAt":'$REPLY'}'
REC=; rec_edit d1 a b; rec_result d1 'Replaced 1 occurrence'; write_text "$dsdir/agents/main/wire.jsonl" "$REC"
proof="$ROOT/proof"
dstate="$D/cache/statusline/$dsid.state"
# an offset that bash arithmetic would evaluate: a[$(...)] runs the command substitution
write_text "$dstate" $'0\t0\t\nK\t0\t0\t-\t-\t-\t-\t-\nF\t'"$dsdir/agents/main/wire.jsonl"$'\ta[$(printf owned > '"$proof"$')]\n'
backdate 1H "$dstate"
render "$D" sid=$dsid
wait_until starts_with "$dstate" $'1\t1\t' && [[ ! -e $proof ]]; check 'a tampered session cache is not evaluated' $? "$(cat "$dstate")"
drules="$D/cache/statusline/cache-rules"
wait_until file_is "$drules" $'0\nk3\t1200\n'; check "server unreachable: Kimi Code's own copy of the cache rules, fetched again next time" $? "$(cat "$drules")"
wait_until file_has "$D/cache/statusline/quota" $'\t\\?\n$'; check '... and the quota marked as failed' $? "$(cat "$D/cache/statusline/quota")"
# a tampered quota cache: numbers only, nothing evaluated (r5 ends up in arithmetic)
now=$(date +%s)
write_text "$D/cache/statusline/quota" "$(( now + 300 ))"$'\t'"$now"$'\t92\tq\t1\ta[$(printf owned > '"$proof"$')]\t2\t3\t4\n'
render "$D"
[[ $CODE == 0 && ! -e $proof && $TEXT == *"$G_QUOTA 5h 1% $DOT 7d 2%"* ]]; check 'a tampered quota cache is not evaluated' $? "$TEXT"
# Kimi Code reached the server since: its newer copy replaces ours
backdate 1M "$drules"
write_kimi_cache_rules "$D" 2400
write_text "$D/cache/statusline/quota" $'0\t0\t90\t?\n'   # a fetch is due
render "$D"
wait_until file_is "$drules" $'0\nk3\t2400\n'; check "... and a newer copy of Kimi Code's replaces it" $? "$(cat "$drules")"
new_home kimiE base="$BASE_URL" tui=; E=$REPLY
text_of "$E/config.toml"
cfg=${T/'[providers."managed:kimi-code"]'/"  [providers.'managed:kimi-code']"}
cfg=${cfg/'[providers."managed:kimi-code".oauth]'/"[ providers . 'managed:kimi-code' . oauth ]"}
write_text "$E/config.toml" "$cfg"
run_script "$REPO/install.sh" --kimi-home "$E" "${INSTALL_ARGS[@]}"
render "$E"
wait_until file_has "$E/cache/statusline/quota" $'\tq\t5\t'; check 'provider header spelled another way: quota still fetched' $? "$(cat "$E/cache/statusline/quota")"

# -------------------------------------------------------------------------- web mode ---
echo 'web install'
# piped into bash, the installer must download, not take a statusline.sh in the current folder
wrap="$ROOT/wrapper"
write_text "$wrap/statusline.sh" $'#!/bin/sh\n# kimi-code-statusline-bash decoy\necho decoy\n'
new_home kimiW tui=; W=$REPLY
OUT=$(cd "$wrap" && "$BASH" -s -- --kimi-home "$W" "${INSTALL_ARGS[@]}" < "$REPO/install.sh" 2>&1)
CODE=$?
# (offline, the download fails, and with it the install: but it was the download it tried)
[[ $OUT == *'Downloading https://github.com/'* ]] &&
  { [[ $OUT == *'could not download'* && ! -e $W/statusline-bash ]] ||
    { [[ $CODE == 0 && -f $W/statusline-bash/statusline.sh ]] && ! grep -q decoy "$W/statusline-bash/statusline.sh"; }; }
check 'piped into bash: downloads, ignoring a statusline.sh in the current folder' $? "$OUT"
new_home kimiC tui="$KIMI_DEFAULT_TUI"; C=$REPLY
OUT=$(cat "$REPO/install.sh" | "$BASH" -s -- --kimi-home "$C" --source "http://127.0.0.1:$PORT/download/statusline.sh" "${INSTALL_ARGS[@]}" 2>&1); CODE=$?
[[ $CODE == 0 && $OUT == *Downloading* ]] && cmp -s "$C/statusline-bash/statusline.sh" "$REPO/statusline.sh"
check 'curl | bash: installs a downloaded statusline.sh' $? "$OUT"
render "$C"
[[ $CODE == 0 && $TEXT == 'Ask When Needed | '* ]]; check '... and it renders' $? "$TEXT"
OUT=$(KIMI_CODE_HOME="$ROOT/does-not-exist" "$BASH" -s < "$REPO/install.sh" 2>&1); CODE=$?
[[ $CODE != 0 && $OUT == *'does not exist'* ]]; check 'a missing Kimi home: an error, nothing written' $? "$OUT"

# ---------------------------------------------------------------------------- timing ---
sorted=($(printf '%s\n' "${TIMES[@]}" | sort -n))
median=${sorted[$(( ${#sorted[@]} / 2 ))]}
msg="median $median ms, max ${sorted[${#sorted[@]} - 1]} ms over ${#sorted[@]} runs"
if [[ -n ${CI:-} ]]; then echo "  info  render time: $msg (not checked on CI)"
else (( median < 300 )); check "median render under 300 ms ($msg)" $?; fi

echo
echo "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
