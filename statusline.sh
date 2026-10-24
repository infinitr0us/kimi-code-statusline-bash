#!/usr/bin/env bash
# kimi-code-statusline-bash: a Claude Code style status line for Kimi Code on Windows.
# https://github.com/infinitr0us/kimi-code-statusline-bash (MIT license)
#    Ask When Needed | 󰚩 K3 · max | 󰉋 ~/Desktop | 󰊢 main | 󰪞 5h 5% · 3h41m · 7d 1% · Mon 07:00 | 󱦻 1h23m +120/-45 |  24m
# (no context segment: the TUI's second footer line already shows context usage)
#
# How Kimi Code (2.1.1 to 2.3.1) runs it: `cmd.exe /d /s /c <command>` with a JSON
# snapshot on stdin; only the first stdout line is used. install.ps1 points <command>
# at statusline.cmd, which starts Git Bash on this file. A run still going at 300 ms is
# killed (taskkill /T /F) and its output dropped. Each successful run repaints the
# footer, which schedules the next run ~1 s later, so this runs about once a second
# for as long as Kimi is open.
#
# The render path therefore sticks to bash builtins: in Git Bash every $(...) or pipe
# costs a fork (~15 ms) and every external program ~25 ms more. Slow work runs in
# detached workers that leave cache files for later renders to pick up:
#   --refresh         refetch the plan quota (curl + jq) into cache/statusline/quota, and
#                     once a day Kimi's prompt-cache durations into cache-rules
#   --scan SID SDIR   fold new wire.jsonl records of session SID into SID.state:
#                     changed lines (+/-), the session's current thinking effort, and
#                     what the prompt-cache countdown needs (last model call, turn state)
# A render starts --scan only when a wire.jsonl is newer than SID.state (a builtin
# mtime test), so an idle session costs no scans at all.
#
# Note: jq on Windows emits CRLF line endings, so every jq consumer strips \r.

KSL_VERSION=dev   # stamped with the release tag by tools/build-release.ps1
if [[ ${1:-} == --version ]]; then printf 'kimi-code-statusline-bash %s\n' "$KSL_VERSION"; exit 0; fi

# A bash started by cmd.exe gets only the Windows PATH, without Git's Unix tools.
# In Git Bash, / is the Git install folder wherever that is.
PATH="/usr/bin:/mingw64/bin:/clangarm64/bin:$PATH"

to_unix() { # $1 = Windows path -> REPLY = Git Bash path (C:\Users\x -> /c/Users/x)
  REPLY=${1//\\//}
  if [[ $REPLY =~ ^([A-Za-z]):(.*)$ ]]; then
    REPLY="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  fi
}

# Kimi's own rule: KIMI_CODE_HOME, else ~/.kimi-code. $HOME may be unset when spawned
# from a Windows process, so ~ is USERPROFILE.
if [[ -n ${KIMI_CODE_HOME:-} ]]; then
  to_unix "$KIMI_CODE_HOME"; KHOME=${REPLY%/}
elif [[ -n ${USERPROFILE:-} ]]; then
  to_unix "$USERPROFILE"; KHOME="${REPLY%/}/.kimi-code"
else
  KHOME="$HOME/.kimi-code"
fi

CACHE_DIR="$KHOME/cache/statusline"
# quota: "<next fetch epoch>\t<last good epoch>\t<color>\t<kind>[\t<5h %>\t<5h reset epoch>\t<7d %>
# \t<7d reset epoch>\t<month %>]"; kind "q" = numbers follow ("-" for a missing one: `read`
# would merge an empty field away), "-" = no Kimi Code plan, "?" = no good fetch yet
QUOTA_CACHE="$CACHE_DIR/quota"
QUOTA_TTL=300      # seconds between quota refetches
QUOTA_RETRY=60     # retry delay after a failed refetch
QUOTA_STALE=900    # grey the quota out once the last good fetch is older than this
# cache-rules: "<fetch epoch>", then "<model>\t<seconds>" lines: how long Kimi's server keeps
# a prompt cache, per upstream model id (k3, kimi-for-coding, ...)
CACHE_RULES="$CACHE_DIR/cache-rules"
RULES_TTL=86400    # seconds between refetches of the cache rules (Kimi Code's own interval)
LOCK_STALE=120     # a worker lock older than this is abandoned

esc=$'\e'
RST="${esc}[0m"
WEEKDAYS=(Sun Mon Tue Wed Thu Fri Sat)   # not %a, which follows the locale
# What a value from a cache file or log must look like before it is used: a number without
# leading zeros (bash arithmetic would read 010 as octal, and evaluates anything else), and
# a model id or alias ("-" = none: an empty field would vanish in `IFS=$'\t' read`).
NUM_RE='^(0|[1-9][0-9]{0,14})$'
ID_RE='^[A-Za-z0-9._:/-]{1,64}$'

iso_epoch() { # $1 = "2026-07-18T05:12:14" (UTC, no Z/fraction) -> REPLY = epoch, pure bash
  local y=$((10#${1:0:4})) mo=$((10#${1:5:2})) d=$((10#${1:8:2}))
  local h=$((10#${1:11:2})) mi=$((10#${1:14:2})) s=$((10#${1:17:2}))
  (( mo <= 2 )) && (( y -= 1 ))
  local era=$(( y / 400 )) yoe=$(( y % 400 ))
  local mp=$(( (mo + 9) % 12 ))
  local doy=$(( (153*mp + 2)/5 + d - 1 ))
  local doe=$(( yoe*365 + yoe/4 - yoe/100 + doy ))
  REPLY=$(( (era*146097 + doe - 719468)*86400 + h*3600 + mi*60 + s ))
}

# A worker lock is a file holding "<pid> <epoch>". It counts as abandoned once its owner
# is gone or it is older than LOCK_STALE: a worker killed along with Kimi's process tree
# never gets to clean up.
lock_busy() { # $1 = lock file; true while a live worker holds it
  local pid= ts=
  [[ -f $1 ]] || return 1
  read -r pid ts < "$1" 2>/dev/null
  [[ $pid =~ ^[0-9]+$ && $ts =~ ^[0-9]+$ ]] || return 1
  (( EPOCHSECONDS - ts <= LOCK_STALE )) && kill -0 "$pid" 2>/dev/null
}

spawn() { "$BASH" "$0" "$@" </dev/null >/dev/null 2>&1 & }

# ----------------------------------------------------------------- workers ---
worker_env() {
  # jq: KIMI_STATUSLINE_JQ if set, else the one install.ps1 found (jq-path.txt next to this
  # file; the shell Kimi spawns may not have your PATH), else whatever PATH has
  local p=${KIMI_STATUSLINE_JQ:-} f="${0%[/\\]*}/jq-path.txt"
  [[ -z $p && -f $f ]] && IFS= read -r p < "$f"
  JQ=jq
  if [[ -n $p ]]; then
    to_unix "${p%$'\r'}"
    [[ -f $REPLY ]] && JQ=$REPLY
  fi
  mkdir -p "$CACHE_DIR" 2>/dev/null
}

take_lock() { # $1 = lock file; exits unless this worker now owns it
  LOCK=$1
  if ! { set -C; printf '%s %s\n' "$$" "$EPOCHSECONDS" > "$LOCK"; } 2>/dev/null; then
    set +C
    lock_busy "$LOCK" && exit 0
    printf '%s %s\n' "$$" "$EPOCHSECONDS" > "$LOCK"   # take over an abandoned lock
  fi
  set +C
  trap 'rm -f "$LOCK"' EXIT
}

if [[ ${1:-} == --refresh ]]; then
  worker_env
  take_lock "$CACHE_DIR/quota.lock"

  ok=0 col= data=
  [[ -f $QUOTA_CACHE ]] && IFS=$'\t' read -r _ ok col data < "$QUOTA_CACHE"
  [[ $ok =~ $NUM_RE ]] || ok=0
  data_re=$'^(q(\t[0-9-]{1,15}){5}|-)$'
  [[ $data =~ $data_re ]] || data='?'   # (an older version's text, too)
  save_quota() { # $1 = epoch of the next fetch
    printf '%s\t%s\t%s\t%s\n' "$1" "$ok" "${col:-90}" "$data" > "$QUOTA_CACHE.tmp" &&
      mv -f "$QUOTA_CACHE.tmp" "$QUOTA_CACHE"
  }
  fail() { save_quota $((EPOCHSECONDS + QUOTA_RETRY)); exit 0; }  # keeps the last good numbers

  # config.toml: base_url + oauth key + api_key of the managed kimi provider
  base=""; okey=""; apikey=""; sec=""; plan=0
  prov_re=$'^[[:space:]]*\\[[[:space:]]*providers[[:space:]]*\\.[[:space:]]*["\']managed:kimi-code["\'][[:space:]]*(\\.[[:space:]]*oauth[[:space:]]*)?\\]'
  while IFS= read -r l || [[ -n $l ]]; do
    [[ $l == *managed:kimi-code* ]] && plan=1
    if [[ $l =~ $prov_re ]]; then
      if [[ -n ${BASH_REMATCH[1]} ]]; then sec=oauth; else sec=prov; fi
      continue
    elif [[ $l =~ ^[[:space:]]*\[ ]]; then
      sec=""; continue
    fi
    if [[ $sec == prov ]]; then
      [[ $l =~ ^[[:space:]]*base_url[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]] && base=${BASH_REMATCH[1]}
      [[ $l =~ ^[[:space:]]*api_key[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]  && apikey=${BASH_REMATCH[1]}
    elif [[ $sec == oauth ]]; then
      [[ $l =~ ^[[:space:]]*key[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]      && okey=${BASH_REMATCH[1]}
    fi
  done < "$KHOME/config.toml"
  # no Kimi Code plan anywhere in config.toml (only other providers' API keys): "-" tells
  # renders to hide the segment
  if (( ! plan )); then data=- col=90; save_quota $((EPOCHSECONDS + QUOTA_TTL)); exit 0; fi
  [[ -z $base ]] && base="https://api.kimi.com/coding/v1"

  # The prompt-cache rules Kimi Code itself uses for its "cache expired" dialog: one public
  # config (no token) on the same server. Until a fetch works, Kimi Code's own cached copy.
  fetched=0
  [[ -f $CACHE_RULES ]] && read -r fetched < "$CACHE_RULES"
  [[ $fetched =~ $NUM_RE ]] || fetched=0
  if (( EPOCHSECONDS - fetched >= RULES_TTL )); then
    rules_jq='.config.config | to_entries[] | select(.value.cache_duration | type == "number")
      | "\(.key)\t\(.value.cache_duration | floor)"'
    rules=$(curl -sf -m 8 -H 'Content-Type: application/json' -d '{"name":"estimated_cache_duration"}' \
      "${base%/}/client_configs" 2>/dev/null | "$JQ" -r "select(.name == \"estimated_cache_duration\") | $rules_jq" 2>/dev/null | tr -d '\r')
    if [[ -n $rules ]]; then
      printf '%s\n%s\n' "$EPOCHSECONDS" "$rules" > "$CACHE_RULES.tmp" && mv -f "$CACHE_RULES.tmp" "$CACHE_RULES"
    else
      # Kimi Code's copy, if newer than ours (Kimi Code may have reached the server since)
      own=
      for f in "$KHOME"/cache/client-configs/*estimated_cache_duration.json; do
        [[ -f $f && ( -z $own || $f -nt $own ) ]] && own=$f
      done
      if [[ -n $own && ( ! -f $CACHE_RULES || $own -nt $CACHE_RULES ) ]]; then
        rules=$("$JQ" -r "$rules_jq" "$own" 2>/dev/null | tr -d '\r')
        # fetch epoch 0: try the server again on the next run
        [[ -n $rules ]] && printf '0\n%s\n' "$rules" > "$CACHE_RULES.tmp" && mv -f "$CACHE_RULES.tmp" "$CACHE_RULES"
      fi
    fi
  fi

  # The OAuth access token lives ~15 min and only Kimi refreshes it (when it makes a
  # request). Never touch the credentials here; just skip the fetch while it is expired.
  token="" exp=0
  for f in "$KHOME/credentials/${okey##*/}.json" "$KHOME/credentials/kimi-code.json"; do
    [[ -f $f ]] || continue
    IFS=$'\t' read -r token exp < <("$JQ" -r '[.access_token // "", (.expires_at // 0 | tostring)] | @tsv' "$f" 2>/dev/null | tr -d '\r')
    [[ -n $token ]] && break
  done
  if [[ -n $token ]]; then
    [[ $exp =~ ^[0-9]+$ ]] && (( exp > 0 && exp <= EPOCHSECONDS )) && fail
  else
    token=$apikey
  fi
  [[ -z $token ]] && fail

  # header via a stdin config file, so the token never shows up in a process command line
  resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sf -m 8 -K - "${base%/}/usages" 2>/dev/null)
  [[ -z $resp ]] && fail

  # "-" for a missing value: `read` would merge an empty field away and shift the rest
  IFS=$'\t' read -r p5 r5 p7 r7 pm rm < <("$JQ" -r '
    def num(x): (x | if type=="string" then tonumber else . end) // 0;
    def pct(u;l): if num(l)>0 then ((num(u)*100/num(l))|round|tostring) else "-" end;
    ((.limits // []) | map(select(.window and .window.duration==300 and .window.timeUnit=="TIME_UNIT_MINUTE")) | .[0] // {}) as $w
    | ($w.detail // {}) as $wd
    | (.usage // {}) as $wk
    | (.usages // {}) as $u2
    | ($u2.limit_5h // {}) as $n5
    | ($u2.limit_7d // {}) as $n7
    | ($u2.month_total // $u2.monthTotal // {}) as $mo
    | [ (if ($wd|length)>0 then pct($wd.used; $wd.limit)
         elif ($n5.used_ratio != null) then (($n5.used_ratio*100)|round|tostring)
         else "-" end),
        ($wd.resetTime // $n5.reset_time // "-"),
        (if ($wk|length)>0 then pct($wk.used; $wk.limit)
         elif ($n7.used_ratio != null) then (($n7.used_ratio*100)|round|tostring)
         else "-" end),
        ($wk.resetTime // $n7.reset_time // "-"),
        (if ($mo.used_ratio != null) then (($mo.used_ratio*100)|round|tostring) else "-" end),
        ($mo.reset_time // $mo.resetTime // "-")
      ] | map(if . == "" then "-" else . end) | @tsv' <<<"$resp" 2>/dev/null | tr -d '\r')
  [[ $p5 =~ ^[0-9]+$ || $p7 =~ ^[0-9]+$ || $pm =~ ^[0-9]+$ ]] || fail

  reset_epoch() { # $1 = reset time, ISO 8601 UTC ("-" if none) -> epoch, or "-"
    local t=${1%Z} e=; t=${t%.*}
    [[ -n $t && $t != - ]] && e=$(date -d "${t}Z" +%s 2>/dev/null)
    [[ $e =~ $NUM_RE ]] || e=-
    printf '%s' "$e"
  }
  r5=$(reset_epoch "$r5")
  r7=$(reset_epoch "$r7")

  maxp=0
  for p in "$p5" "$p7" "$pm"; do [[ $p =~ ^[0-9]+$ ]] && (( p > maxp )) && maxp=$p; done
  if   (( maxp >= 85 )); then col=91
  elif (( maxp >= 60 )); then col=93
  else col=92; fi

  data=q
  for v in "$p5" "$r5" "$p7" "$r7" "$pm"; do
    [[ $v =~ $NUM_RE ]] || v=-
    data+=$'\t'$v
  done
  ok=$EPOCHSECONDS
  # fetch again just after a window resets, so its percentage doesn't linger (a reset that
  # has passed already is the server's lag: the usual interval then)
  next=$(( EPOCHSECONDS + QUOTA_TTL ))
  for r in "$r5" "$r7"; do
    [[ $r =~ $NUM_RE ]] && (( r + 5 > EPOCHSECONDS && r + 5 < next )) && next=$(( r + 5 ))
  done
  save_quota "$next"
  exit 0
fi

# jq program for --scan. Input: one raw chunk of wire.jsonl (-Rs). Output lines:
#   C <callId> <added> <removed>   an Edit/Write call (counted once its result is in)
#   R <callId> <ok 0|1> <times>    a tool result; times = N of "Replaced N occurrences"
#   E <effort>                     last thinkingEffort in the chunk (main agent only)
#   U <epoch> <model> <alias>      last completed model call of a turn (main agent only;
#                                  each one refreshes the server's prompt cache): its
#                                  upstream model id (k3) and Kimi's alias (kimi-code/k3)
#   A <alias>                      the model selected last (a request or a /model switch)
#   Q <alias> <model>              the last request, carried into the next chunk ($ra, $rm):
#                                  its completion may come in a later chunk
#   T <1|0>                        last turn boundary: started / ended, Esc included (main)
#   B                              the end: jq got through the whole chunk. Only complete
#                                  lines count; a record still being written is left for
#                                  the next scan
# Edit counts are a real line diff (common head/tail trimmed, LCS on the rest), like
# Claude Code's, instead of every old_string/new_string line.
JQ_SCAN='
def lines: if type != "string" or . == "" then [] else (if endswith("\n") then .[:-1] else . end | split("\n")) end;
def lcslen($a; $b):
  reduce range(0; $a | length) as $i ([range(0; ($b | length) + 1) | 0];
    . as $prev
    | reduce range(0; $b | length) as $j ([0];
        . + [if $a[$i] == $b[$j] then $prev[$j] + 1 else ([.[$j], $prev[$j + 1]] | max) end]))
  | .[-1];
def diffcount($o; $n):
  ([($o | length), ($n | length)] | min) as $m
  | (first(range(0; $m) as $i | select($o[$i] != $n[$i]) | $i) // $m) as $p
  | (first(range(0; $m - $p) as $i | select($o[($o | length) - 1 - $i] != $n[($n | length) - 1 - $i]) | $i) // ($m - $p)) as $s
  | $o[$p:($o | length) - $s] as $a
  | $n[$p:($n | length) - $s] as $b
  | (if ($a | length) * ($b | length) <= 250000 then lcslen($a; $b) else 0 end) as $l
  | [($b | length) - $l, ($a | length) - $l];
split("\n")[:-1] as $done
| [$done[] | fromjson? | objects] as $recs
| ( $recs[]
    | select(.type == "context.append_loop_event") | .event | objects
    | if .type == "tool.call" and (.name == "Edit" or .name == "Write") then
        (.args | objects) as $x
        | (if .name == "Edit" then diffcount($x.old_string | lines; $x.new_string | lines)
           else [($x.content | lines | length), 0] end) as $d
        | "C\t\(.toolCallId)\t\($d[0])\t\($d[1])"
      elif .type == "tool.result" then
        "R\t\(.toolCallId)\t\(if .result.isError then 0 else 1 end)\t\((.result.output | strings | capture("^Replaced (?<n>[0-9]+) occurrence") | .n | tonumber) // 1)"
      else empty end ),
  ( if $main then
      (([$recs[] | .thinkingEffort? | strings] | last) // empty | "E\t\(.)"),
      ( reduce ($recs[] | select((.agentId // "main") == "main")) as $r ({ra: $ra, rm: $rm};
          if $r.type == "llm.request" and ($r.kind // "loop") == "loop" then
            .ra = (($r.modelAlias | strings) // "-") | .rm = (($r.model | strings) // "-") | .cur = .ra
          elif $r.type == "usage.record" and ($r.usageScope // "turn") == "turn" and ($r.time | type) == "number" then
            (($r.model | strings) // .ra) as $a
            | .u = [($r.time / 1000 | floor), (if $a == .ra then .rm else ($a | sub("^.*/"; "")) end), $a]
          elif $r.type == "config.update" and ($r.modelAlias | type) == "string" then .cur = $r.modelAlias
          else . end)
        | (if .u then "U\t\(.u[0])\t\(.u[1])\t\(.u[2])" else empty end),
          (if .cur then "A\t\(.cur)" else empty end),
          "Q\t\(.ra)\t\(.rm)" ),
      (([$recs[] | .type | select(. == "agent.turn.started" or . == "turn.prompt" or . == "agent.turn.ended" or . == "turn.ended")]
         | last) // empty | "T\t\(if . == "agent.turn.started" or . == "turn.prompt" then 1 else 0 end)")
    else empty end ),
  "B"
'

if [[ ${1:-} == --scan ]]; then
  sid=$2 sdir=$3
  [[ -n $sid && -d $sdir ]] || exit 0
  worker_env
  take_lock "$CACHE_DIR/$sid.scan.lock"
  t0=$EPOCHSECONDS
  st="$CACHE_DIR/$sid.state"
  # SID.state: "<added>\t<removed>\t<effort>", then "K\t<last model call epoch>\t<in a turn
  # 1|0>\t<its model>\t<its alias>\t<alias selected now>\t<last request's alias>\t<..model>"
  # (the render reads these two lines), "F\t<wire file>\t<bytes consumed>" and
  # "P\t<callId>\t<added>:<removed>" for Edit/Write calls still awaiting their result.
  pend_re='^(0|[1-9][0-9]{0,8}):(0|[1-9][0-9]{0,8})$'
  reset_k() { used=0 busy=0 model=- alias=- cur=- ra=- rm=-; }
  added=0 removed=0 effort= kline=0
  reset_k
  declare -A off=() pend=() size=()
  if [[ -f $st ]]; then
    { IFS=$'\t' read -r added removed effort
      # numbers only: these end up in arithmetic, which would evaluate anything else
      while IFS=$'\t' read -r k a b c d e g h; do
        case $k in
          F) [[ $b =~ $NUM_RE ]] && off[$a]=$b;;
          P) [[ $b =~ $pend_re ]] && pend[$a]=$b;;
          K) if [[ $a =~ $NUM_RE && $b == [01] && $c =~ $ID_RE && $d =~ $ID_RE && $e =~ $ID_RE &&
                   $g =~ $ID_RE && $h =~ $ID_RE ]]; then
               used=$a busy=$b model=$c alias=$d cur=$e ra=$g rm=$h kline=1
             fi;;
        esac
      done
    } < "$st"
    # written by a version without this K line (or a broken one): read the logs again from
    # the start
    (( kline )) || { added=0 removed=0; off=(); pend=(); }
  fi
  [[ $added =~ $NUM_RE ]] || added=0
  [[ $removed =~ $NUM_RE ]] || removed=0

  files=( "$sdir"/agents/*/wire.jsonl )
  [[ -f ${files[0]} ]] || exit 0
  while IFS= read -r l; do size[${l#* }]=${l%% *}; done < <(stat -c '%s %n' -- "${files[@]}")
  # a log that shrank was rewritten: recount everything from scratch
  for f in "${files[@]}"; do
    if (( ${size[$f]:-0} < ${off[$f]:-0} )); then added=0 removed=0; reset_k; off=(); pend=(); break; fi
  done

  if command -v "$JQ" >/dev/null 2>&1; then
    for f in "${files[@]}"; do
      o=${off[$f]:-0} s=${size[$f]:-0}
      (( s > o )) || continue
      main=false; [[ $f == */agents/main/wire.jsonl ]] && main=true
      mapfile -t out < <(tail -c +$((o + 1)) -- "$f" | head -c $((s - o)) |
        "$JQ" -Rsr --argjson main "$main" --arg ra "$ra" --arg rm "$rm" "$JQ_SCAN" 2>/dev/null | tr -d '\r')
      # apply a chunk only if jq got all the way through it
      (( ${#out[@]} )) && [[ ${out[-1]} == B ]] || continue
      # Bytes consumed: the complete lines, so a record still being written is read whole by
      # the next scan. Counted here: jq's utf8bytelength of a raw line is off for some text
      # (long runs of emoji or U+FFFD, in jq 1.6 and 1.7), which would skip into a record.
      n=$(( s - o ))
      if [[ -n $(tail -c +"$s" -- "$f" | head -c 1) ]]; then   # (a newline would be stripped)
        p=$(tail -c +$((o + 1)) -- "$f" | head -c "$n" | tail -n 1 | wc -c)
        [[ $p =~ $NUM_RE ]] && (( p <= n )) || continue
        n=$(( n - p ))
      fi
      off[$f]=$(( o + n ))
      for l in "${out[@]}"; do
        IFS=$'\t' read -r k a b c <<< "$l"
        case $k in
          C) [[ $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ ]] && pend[$a]="$b:$c" ;;
          R) v=${pend[$a]-}
             [[ -n $v ]] || continue
             unset 'pend[$a]'
             [[ $b == 1 ]] || continue          # failed or declined: nothing changed
             [[ $c =~ ^[0-9]+$ ]] || c=1
             (( added += ${v%%:*} * c, removed += ${v#*:} * c )) ;;
          E) effort=$a ;;
          U) [[ $a =~ $NUM_RE && $b =~ $ID_RE && $c =~ $ID_RE ]] && used=$a model=$b alias=$c ;;
          A) [[ $a =~ $ID_RE ]] && cur=$a ;;
          Q) [[ $a =~ $ID_RE && $b =~ $ID_RE ]] && ra=$a rm=$b ;;
          T) [[ $a == [01] ]] && busy=$a ;;
        esac
      done
    done
  fi

  { printf '%s\t%s\t%s\n' "$added" "$removed" "$effort"
    printf 'K\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$used" "$busy" "$model" "$alias" "$cur" "$ra" "$rm"
    for f in "${!off[@]}"; do printf 'F\t%s\t%s\n' "$f" "${off[$f]}"; done
    for id in "${!pend[@]}"; do printf 'P\t%s\t%s\n' "$id" "${pend[$id]}"; done
  } > "$st.tmp" || exit 0
  # Backdate the state to just before this scan started: anything appended since then
  # leaves a wire.jsonl newer than the state, so the next render schedules another scan.
  touch -d "@$(( t0 - 1 ))" "$st.tmp"
  mv -f "$st.tmp" "$st"
  exit 0
fi

# ----------------------------------------------------------------- render ---
[[ -t 0 ]] && exit 0                          # not fed by Kimi: don't wait on a terminal
IFS= read -r -d '' input || [[ -n $input ]]   # slurp stdin without forking cat

jstr() { # $1 = key -> REPLY = its string value in the snapshot ('' when absent or null)
  local re='"'$1'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  REPLY=
  [[ $input =~ $re ]] && REPLY=${BASH_REMATCH[1]}
}

config_effort() { # REPLY = [thinking].effort, else default_model's default_effort; "off" when disabled
  local l eff= tsec=0 toff=0 dmodel= cur= ovr=0
  local -A effmap=()
  REPLY=
  [[ -f $KHOME/config.toml ]] || return
  while IFS= read -r l || [[ -n $l ]]; do
    if   [[ $l =~ ^default_model[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then dmodel=${BASH_REMATCH[1]}
    elif [[ $l =~ ^\[thinking\] ]]; then tsec=1; cur=; continue
    elif [[ $l =~ ^\[models\.\"([^\"]+)\"\.overrides\] ]]; then cur=${BASH_REMATCH[1]}; ovr=1; tsec=0; continue
    elif [[ $l =~ ^\[models\.\"([^\"]+)\"\] ]]; then cur=${BASH_REMATCH[1]}; ovr=0; tsec=0; continue
    elif [[ $l =~ ^\[ ]]; then tsec=0; cur=; continue
    fi
    if (( tsec )); then
      [[ $l =~ ^[[:space:]]*effort[[:space:]]*=[[:space:]]*\"([a-zA-Z]+)\" ]] && eff=${BASH_REMATCH[1]}
      [[ $l =~ ^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false ]] && toff=1
    elif [[ -n $cur && $l =~ ^[[:space:]]*default_effort[[:space:]]*=[[:space:]]*\"([a-zA-Z]+)\" ]]; then
      { [[ -z ${effmap[$cur]:-} ]] || (( ovr )); } && effmap[$cur]=${BASH_REMATCH[1]}
    fi
  done < "$KHOME/config.toml"
  (( toff )) && eff=off
  [[ -z $eff && -n $dmodel ]] && eff=${effmap[$dmodel]:-}
  REPLY=$eff
}

jstr model;          model=$REPLY
jstr gitBranch;      git_branch=$REPLY
jstr cwd;            cwd=${REPLY//\\\\/\\}
jstr permissionMode; perm=$REPLY
jstr sessionId;      sid=$REPLY

# session: elapsed time, changed lines, thinking effort and the prompt cache's state (all
# but the first from SID.state)
added=0 removed=0 effort= el= cused=0 cbusy=0 cmodel=- calias=- ccur=-
if [[ -n $sid ]]; then
  sdir=""
  pcache="$CACHE_DIR/$sid.path"
  [[ -f $pcache ]] && read -r sdir < "$pcache"
  if [[ -z $sdir || ! -d $sdir ]]; then
    sdir=""
    for g in "$KHOME"/sessions/*/"$sid"; do
      [[ -d $g ]] && { sdir=$g; break; }
    done
    if [[ -z $sdir ]]; then   # not in the usual place: look it up (one grep per session)
      iline=$(grep -m1 -F "\"sessionId\":\"$sid\"" "$KHOME/session_index.jsonl" 2>/dev/null)
      if [[ $iline =~ \"sessionDir\":\"(([^\"\\]|\\.)*)\" ]]; then
        w=${BASH_REMATCH[1]//\\\\/\\}             # C:\\Users\\.. -> C:\Users\..
        wp=${w//\\//}; d=${wp:0:1}
        [[ -d /${d,,}${wp:2} ]] && sdir="/${d,,}${wp:2}"
      fi
    fi
    if [[ -n $sdir ]]; then
      [[ -d $CACHE_DIR ]] || mkdir -p "$CACHE_DIR" 2>/dev/null
      printf '%s\n' "$sdir" > "$pcache" 2>/dev/null
    fi
  fi

  if [[ -n $sdir ]]; then
    # elapsed: createdAt is epoch-ms in newer sessions, ISO string in older ones
    ep=""
    if [[ -f $sdir/state.json ]]; then
      IFS= read -r -d '' sj < "$sdir/state.json"
      if [[ $sj =~ \"createdAt\":[[:space:]]*([0-9]+) ]]; then
        ep=${BASH_REMATCH[1]}
        (( ep > 20000000000 )) && ep=$(( ep / 1000 ))
      elif [[ $sj =~ \"createdAt\":[[:space:]]*\"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        iso_epoch "${BASH_REMATCH[1]}"; ep=$REPLY
      fi
    fi
    if [[ -n $ep ]]; then
      s=$(( EPOCHSECONDS - ep )); (( s < 0 )) && s=0
      d=$(( s / 86400 )) h=$(( s % 86400 / 3600 )) mm=$(( s % 3600 / 60 ))
      if   (( d > 0 )); then el="${d}d${h}h"
      elif (( h > 0 )); then printf -v el '%dh%02dm' "$h" "$mm"
      else el="${mm}m"; fi
    fi

    st="$CACHE_DIR/$sid.state"
    k=
    [[ -f $st ]] && { IFS=$'\t' read -r added removed effort; IFS=$'\t' read -r k cused cbusy cmodel calias ccur _; } < "$st"
    [[ $k == K && $cused =~ $NUM_RE && $cbusy == [01] && $cmodel =~ $ID_RE && $calias =~ $ID_RE && $ccur =~ $ID_RE ]] ||
      cused=0 cbusy=0 cmodel=- calias=- ccur=-
    # the main log has records the state doesn't have yet: most likely a turn is running
    [[ $sdir/agents/main/wire.jsonl -nt $st ]] && cbusy=1
    for f in "$sdir"/agents/*/wire.jsonl; do
      if [[ $f -nt $st ]]; then
        lock_busy "$CACHE_DIR/$sid.scan.lock" || spawn --scan "$sid" "$sdir"
        break
      fi
    done
  fi
fi
[[ $added =~ $NUM_RE ]] || added=0
[[ $removed =~ $NUM_RE ]] || removed=0
[[ $effort =~ ^[A-Za-z0-9_-]{0,20}$ ]] || effort=
# the session log has the effort actually in use; config.toml only until it is scanned
if [[ -z $effort ]]; then config_effort; effort=$REPLY; fi
[[ $effort == on ]] && effort=thinking        # thinking on, model without effort levels

parts=()

# permission mode under Kimi's own names (PERMISSION_MODE_DISPLAY_NAMES in Kimi Code 2.2),
# color-coded by how much runs unasked: Always Ask green / Ask When Needed yellow /
# Never Ask red. Kimi 2.x's "yolo" is the middle mode; "auto" approves everything.
case $perm in
  manual) pc=92 pl="Always Ask";;
  yolo)   pc=93 pl="Ask When Needed";;
  auto)   pc=91 pl="Never Ask";;
  *)      pc=97 pl=$perm;;
esac
seg=""
[[ -n $perm ]] && seg="${esc}[1;${pc}m${pl}${RST}"
[[ $input =~ \"planMode\"[[:space:]]*:[[:space:]]*true ]] && seg+="${seg:+ }${esc}[1;95mplan${RST}"
[[ -n $seg ]] && parts+=("$seg")

# model · effort
m="${esc}[1;96m󰚩 ${model}${RST}"
[[ -n $effort ]] && m+=" ${esc}[96m· ${effort}${RST}"
parts+=("$m")

# directory: ~ for the user's home, then the last 3 components (like Kimi's own footer)
disp=${cwd//\\//}
if [[ -n $disp ]]; then
  home=${USERPROFILE//\\//}
  if [[ -n $home ]]; then
    shopt -s nocasematch                        # Windows paths are case-insensitive
    if   [[ $disp == "$home" ]];   then disp="~"
    elif [[ $disp == "$home"/* ]]; then disp="~${disp:${#home}}"
    fi
    shopt -u nocasematch
  fi
  [[ $disp =~ ^.+/([^/]+/[^/]+/[^/]+)$ ]] && disp="…/${BASH_REMATCH[1]}"
  parts+=("${esc}[93m󰉋${RST} ${esc}[1;92m${disp}${RST}")
fi

# git branch
[[ -n $git_branch ]] && parts+=("${esc}[1;94m󰊢 ${git_branch}${RST}")

# quota (from cache; refetched by a detached worker when due), like ccline 2 in Claude
# Code: the 5-hour window with the time left, the week with its reset day and time
qnext=0 qok=0 qcol="" qkind="" p5="" r5="" p7="" r7="" pm=""
[[ -f $QUOTA_CACHE ]] && IFS=$'\t' read -r qnext qok qcol qkind p5 r5 p7 r7 pm < "$QUOTA_CACHE"
[[ $qnext =~ $NUM_RE ]] || qnext=0
[[ $qok =~ $NUM_RE ]] || qok=0
[[ $qcol =~ ^[0-9]{1,3}$ ]] || qcol=90
case $qkind in q|-|'?') ;; *) qkind="" qnext=0;; esac   # an older version's cache: refetch
if (( EPOCHSECONDS >= qnext )) && ! lock_busy "$CACHE_DIR/quota.lock"; then spawn --refresh; fi
if [[ $qkind == q ]]; then
  qtext=""
  if [[ $p5 =~ ^[0-9]{1,4}$ ]]; then
    qtext="5h ${p5}%"
    if [[ $r5 =~ $NUM_RE ]]; then
      t=$(( r5 > EPOCHSECONDS ? (r5 - EPOCHSECONDS + 59) / 60 : 0 ))   # minutes, rounded up
      if (( t >= 60 )); then printf -v t '%dh%02dm' $(( t / 60 )) $(( t % 60 )); else t+=m; fi
      qtext+=" · $t"
    fi
  fi
  if [[ $p7 =~ ^[0-9]{1,4}$ ]]; then
    qtext+="${qtext:+ · }7d ${p7}%"
    if [[ $r7 =~ $NUM_RE ]]; then
      printf -v t '%(%w %H:%M)T' "$r7"                # local time, as a bash builtin
      qtext+=" · ${WEEKDAYS[${t%% *}]} ${t#* }"
    fi
  fi
  [[ $pm =~ ^[0-9]{1,4}$ ]] && qtext+="${qtext:+ · }mo ${pm}%"
  (( EPOCHSECONDS - qok > QUOTA_STALE )) && qcol=90   # last good fetch is old: grey it out
  [[ -n $qtext ]] && parts+=("${esc}[${qcol}m󰪞 ${qtext}${RST}")
elif [[ $qkind == '?' ]]; then
  parts+=("${esc}[90m󰪞 ?${RST}")                     # fetching fails, no numbers yet
elif [[ $qkind != - ]]; then                          # "-": no Kimi Code plan, nothing to show
  parts+=("${esc}[90m󰪞 …${RST}")                     # the first fetch is still running
fi

# session: elapsed time + changed lines
sess=$el
if (( added > 0 || removed > 0 )); then
  sess+="${sess:+ }${esc}[92m+${added}${RST}/${esc}[91m-${removed}${RST}"
fi
[[ -n $sess ]] && parts+=("${esc}[1;92m󱦻${RST} ${sess}")

# Prompt cache, between turns: minutes until Kimi's server drops this session's cache, by
# Kimi Code's own estimate for the model (cache-rules), counted from the last model call.
# Every call refreshes the cache, so during a turn the countdown is hidden, unless the
# cache has expired anyway (a long tool run, or a turn that never logged its end). Another
# model selected since then (/model) won't find the cache either: "cold" as well.
# Blue, yellow in the last 5 minutes, then "cold", as in the Claude Code status line.
ttl=""
if (( cused > 0 )) && [[ -f $CACHE_RULES ]]; then
  { read -r _
    while IFS=$'\t' read -r k t; do [[ $k == "$cmodel" ]] && { ttl=$t; break; }; done
  } < "$CACHE_RULES"
fi
if [[ $ttl =~ $NUM_RE ]] && (( ttl > 0 )); then
  t=$(( cused + ttl - EPOCHSECONDS ))
  if (( t <= 0 )) || [[ $ccur != - && $ccur != "$calias" ]]; then
    parts+=("${esc}[33m cold${RST}")
  elif [[ $cbusy == 0 ]]; then
    c=34; (( t < 300 )) && c=33
    parts+=("${esc}[${c}m $(( (t + 59) / 60 ))m${RST}")
  fi
fi

out=""
for p in "${parts[@]}"; do out+="${out:+${esc}[90m | ${RST}}$p"; done
printf '%s\n' "$out"
