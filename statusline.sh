#!/usr/bin/env bash
# kimi-code-statusline-bash: a Claude Code style status line for Kimi Code on Windows.
# https://github.com/infinitr0us/kimi-code-statusline-bash (MIT license)
#    Ask When Needed | 󰚩 K3 · max | 󰉋 ~/Desktop | 󰊢 main | 󰪞 5h 5% (rst 00:34) · 7d 1% (rst 09/28 03:34) | 󱦻 1h23m +120/-45
# (no context segment: the TUI's second footer line already shows context usage)
#
# How Kimi Code (2.1.1 to 2.2.0) runs it: `cmd.exe /d /s /c <command>` with a JSON
# snapshot on stdin; only the first stdout line is used. install.ps1 points <command>
# at statusline.cmd, which starts Git Bash on this file. A run still going at 300 ms is
# killed (taskkill /T /F) and its output dropped. Each successful run repaints the
# footer, which schedules the next run ~1 s later, so this runs about once a second
# for as long as Kimi is open.
#
# The render path therefore sticks to bash builtins: in Git Bash every $(...) or pipe
# costs a fork (~15 ms) and every external program ~25 ms more. Slow work runs in
# detached workers that leave cache files for later renders to pick up:
#   --refresh         refetch the plan quota (curl + jq) into cache/statusline/quota
#   --scan SID SDIR   fold new wire.jsonl records of session SID into SID.state:
#                     changed lines (+/-) and the session's current thinking effort
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
QUOTA_CACHE="$CACHE_DIR/quota"   # "<next fetch epoch>\t<last good epoch>\t<color>\t<text>"; text "-" = no plan
QUOTA_TTL=300      # seconds between quota refetches
QUOTA_RETRY=60     # retry delay after a failed refetch
QUOTA_STALE=900    # grey the quota out once the last good fetch is older than this
LOCK_STALE=120     # a worker lock older than this is abandoned

esc=$'\e'
RST="${esc}[0m"

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
  # jq: the one install.ps1 found (KIMI_STATUSLINE_JQ, set by statusline.cmd), since
  # the shell Kimi spawns may not have the same PATH; otherwise whatever PATH has
  JQ=jq
  if [[ -n ${KIMI_STATUSLINE_JQ:-} ]]; then
    to_unix "$KIMI_STATUSLINE_JQ"
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

  ok=0 col= text=
  [[ -f $QUOTA_CACHE ]] && IFS=$'\t' read -r _ ok col text < "$QUOTA_CACHE"
  [[ $ok =~ ^[0-9]+$ ]] || ok=0
  save_quota() { # $1 = epoch of the next fetch
    printf '%s\t%s\t%s\t%s\n' "$1" "$ok" "${col:-90}" "${text:-?}" > "$QUOTA_CACHE.tmp" &&
      mv -f "$QUOTA_CACHE.tmp" "$QUOTA_CACHE"
  }
  fail() { save_quota $((EPOCHSECONDS + QUOTA_RETRY)); exit 0; }  # keeps the last good text

  # config.toml: base_url + oauth key + api_key of the managed kimi provider
  base=""; okey=""; apikey=""; sec=""; plan=0
  while IFS= read -r l || [[ -n $l ]]; do
    case $l in
      \[providers.\"managed:kimi-code\".oauth\]*) sec=oauth; continue;;
      \[providers.\"managed:kimi-code\"\]*)       sec=prov; plan=1; continue;;
      \[*)                                        sec="";    continue;;
    esac
    if [[ $sec == prov ]]; then
      [[ $l =~ ^[[:space:]]*base_url[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]] && base=${BASH_REMATCH[1]}
      [[ $l =~ ^[[:space:]]*api_key[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]  && apikey=${BASH_REMATCH[1]}
    elif [[ $sec == oauth ]]; then
      [[ $l =~ ^[[:space:]]*key[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]      && okey=${BASH_REMATCH[1]}
    fi
  done < "$KHOME/config.toml"
  # no Kimi Code plan (only other providers' API keys): "-" tells renders to hide the segment
  if (( ! plan )); then text=- col=90; save_quota $((EPOCHSECONDS + QUOTA_TTL)); exit 0; fi
  [[ -z $base ]] && base="https://api.kimi.com/coding/v1"

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

  IFS=$'\t' read -r p5 r5 p7 r7 pm rm < <("$JQ" -r '
    def num(x): (x | if type=="string" then tonumber else . end) // 0;
    def pct(u;l): if num(l)>0 then ((num(u)*100/num(l))|round|tostring) else "" end;
    ((.limits // []) | map(select(.window and .window.duration==300 and .window.timeUnit=="TIME_UNIT_MINUTE")) | .[0] // {}) as $w
    | ($w.detail // {}) as $wd
    | (.usage // {}) as $wk
    | (.usages // {}) as $u2
    | ($u2.limit_5h // {}) as $n5
    | ($u2.limit_7d // {}) as $n7
    | ($u2.month_total // $u2.monthTotal // {}) as $mo
    | [ (if ($wd|length)>0 then pct($wd.used; $wd.limit)
         elif ($n5.used_ratio != null) then (($n5.used_ratio*100)|round|tostring)
         else "" end),
        ($wd.resetTime // $n5.reset_time // ""),
        (if ($wk|length)>0 then pct($wk.used; $wk.limit)
         elif ($n7.used_ratio != null) then (($n7.used_ratio*100)|round|tostring)
         else "" end),
        ($wk.resetTime // $n7.reset_time // ""),
        (if ($mo.used_ratio != null) then (($mo.used_ratio*100)|round|tostring) else "" end),
        ($mo.reset_time // $mo.resetTime // "")
      ] | @tsv' <<<"$resp" 2>/dev/null | tr -d '\r')
  [[ $p5 =~ ^[0-9]+$ || $p7 =~ ^[0-9]+$ || $pm =~ ^[0-9]+$ ]] || fail

  fmt_reset() { # $1 iso-utc $2 date-fmt
    local t=${1%Z}; t=${t%.*}
    [[ -z $t ]] && return
    date -d "${t}Z" +"$2" 2>/dev/null
  }
  r5s=$(fmt_reset "$r5" "%H:%M")
  r7s=$(fmt_reset "$r7" "%m/%d %H:%M")

  maxp=0
  for p in "$p5" "$p7" "$pm"; do [[ $p =~ ^[0-9]+$ ]] && (( p > maxp )) && maxp=$p; done
  if   (( maxp >= 85 )); then col=91
  elif (( maxp >= 60 )); then col=93
  else col=92; fi

  text=""
  [[ $p5 =~ ^[0-9]+$ ]] && text+="5h ${p5}%${r5s:+ (rst $r5s)}"
  [[ $p7 =~ ^[0-9]+$ ]] && text+="${text:+ · }7d ${p7}%${r7s:+ (rst $r7s)}"
  [[ $pm =~ ^[0-9]+$ ]] && text+="${text:+ · }mo ${pm}%"
  ok=$EPOCHSECONDS
  save_quota $((EPOCHSECONDS + QUOTA_TTL))
  exit 0
fi

# jq program for --scan. Input: one raw chunk of wire.jsonl (-Rs). Output lines:
#   C <callId> <added> <removed>   an Edit/Write call (counted once its result is in)
#   R <callId> <ok 0|1> <times>    a tool result; times = N of "Replaced N occurrences"
#   E <effort>                     last thinkingEffort in the chunk (main agent only)
#   B <bytes>                      bytes consumed: complete lines only, so a record
#                                  still being written is picked up by the next scan
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
        "R\t\(.toolCallId)\t\(if .result.isError then 0 else 1 end)\t\((.result.output | strings | capture("^Replaced (?<n>[0-9]+) occurrence") | .n) // 1)"
      else empty end ),
  ( if $main then ([$recs[] | .thinkingEffort? | strings] | last) // empty | "E\t\(.)" else empty end ),
  "B\t\($done | map(utf8bytelength + 1) | add // 0)"
'

if [[ ${1:-} == --scan ]]; then
  sid=$2 sdir=$3
  [[ -n $sid && -d $sdir ]] || exit 0
  worker_env
  take_lock "$CACHE_DIR/$sid.scan.lock"
  t0=$EPOCHSECONDS
  st="$CACHE_DIR/$sid.state"
  # SID.state: "<added>\t<removed>\t<effort>", then "F\t<wire file>\t<bytes consumed>"
  # and "P\t<callId>\t<added>:<removed>" for Edit/Write calls still awaiting their result.
  added=0 removed=0 effort=
  declare -A off=() pend=() size=()
  if [[ -f $st ]]; then
    { IFS=$'\t' read -r added removed effort
      while IFS=$'\t' read -r k a b; do
        case $k in F) off[$a]=$b;; P) pend[$a]=$b;; esac
      done
    } < "$st"
  fi
  [[ $added =~ ^[0-9]+$ ]] || added=0
  [[ $removed =~ ^[0-9]+$ ]] || removed=0

  files=( "$sdir"/agents/*/wire.jsonl )
  [[ -f ${files[0]} ]] || exit 0
  while IFS= read -r l; do size[${l#* }]=${l%% *}; done < <(stat -c '%s %n' -- "${files[@]}")
  # a log that shrank was rewritten: recount everything from scratch
  for f in "${files[@]}"; do
    if (( ${size[$f]:-0} < ${off[$f]:-0} )); then added=0 removed=0; off=(); pend=(); break; fi
  done

  if command -v "$JQ" >/dev/null 2>&1; then
    for f in "${files[@]}"; do
      o=${off[$f]:-0} s=${size[$f]:-0}
      (( s > o )) || continue
      main=false; [[ $f == */agents/main/wire.jsonl ]] && main=true
      mapfile -t out < <(tail -c +$((o + 1)) -- "$f" | head -c $((s - o)) |
        "$JQ" -Rsr --argjson main "$main" "$JQ_SCAN" 2>/dev/null | tr -d '\r')
      # apply a chunk only if jq got all the way through it
      (( ${#out[@]} )) && [[ ${out[-1]} == B$'\t'* ]] || continue
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
          B) [[ $a =~ ^[0-9]+$ ]] && off[$f]=$(( o + a )) ;;
        esac
      done
    done
  fi

  { printf '%s\t%s\t%s\n' "$added" "$removed" "$effort"
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

# session: elapsed time, changed lines, thinking effort (the last two from SID.state)
added=0 removed=0 effort= el=
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
    [[ -f $st ]] && IFS=$'\t' read -r added removed effort < "$st"
    for f in "$sdir"/agents/*/wire.jsonl; do
      if [[ $f -nt $st ]]; then
        lock_busy "$CACHE_DIR/$sid.scan.lock" || spawn --scan "$sid" "$sdir"
        break
      fi
    done
  fi
fi
[[ $added =~ ^[0-9]+$ ]] || added=0
[[ $removed =~ ^[0-9]+$ ]] || removed=0
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

# quota (from cache; refetched by a detached worker when due)
qnext=0 qok=0 qcol="" qtext=""
[[ -f $QUOTA_CACHE ]] && IFS=$'\t' read -r qnext qok qcol qtext < "$QUOTA_CACHE"
[[ $qnext =~ ^[0-9]+$ ]] || qnext=0
[[ $qok =~ ^[0-9]+$ ]] || qok=0
if (( EPOCHSECONDS >= qnext )) && ! lock_busy "$CACHE_DIR/quota.lock"; then spawn --refresh; fi
if [[ $qtext == - ]]; then
  :                                                   # no Kimi Code plan: nothing to show
elif [[ -n $qtext ]]; then
  (( EPOCHSECONDS - qok > QUOTA_STALE )) && qcol=90   # last good fetch is old: grey it out
  parts+=("${esc}[${qcol:-90}m󰪞 ${qtext}${RST}")
else
  parts+=("${esc}[90m󰪞 …${RST}")
fi

# session: elapsed time + changed lines
sess=$el
if (( added > 0 || removed > 0 )); then
  sess+="${sess:+ }${esc}[92m+${added}${RST}/${esc}[91m-${removed}${RST}"
fi
[[ -n $sess ]] && parts+=("${esc}[1;92m󱦻${RST} ${sess}")

out=""
for p in "${parts[@]}"; do out+="${out:+${esc}[90m | ${RST}}$p"; done
printf '%s\n' "$out"
