#!/usr/bin/env bash
# Installs kimi-code-statusline-bash, a Claude Code style status line for Kimi Code, on macOS.
# https://github.com/infinitr0us/kimi-code-statusline-bash (MIT license)
#
# Puts statusline.sh into <Kimi home>/statusline-bash and points [status_line] command in
# <Kimi home>/tui.toml at it. <Kimi home> is KIMI_CODE_HOME, else ~/.kimi-code. Files it
# replaces are backed up first, and uninstall.sh undoes the install. Running it again
# upgrades in place.
#
# From a release zip or a clone it installs the statusline.sh next to it. Run from the
# web, it downloads statusline.sh from the GitHub release:
#     curl -fsSL https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/install.sh | bash
#
# Options (after `bash -s --` when piped from curl):
#   --version TAG    release to download statusline.sh from, such as v0.3.0. Default: the
#                    latest release. Not used when a statusline.sh sits next to this script.
#   --source PATH    path or http(s) URL of the statusline.sh to install, instead of the above
#   --kimi-home DIR  Kimi Code's home folder. Default: KIMI_CODE_HOME, else ~/.kimi-code.
#   --bash PATH      the bash that runs the status line. Default: /bin/bash (macOS's own).
#   --jq PATH        jq. Default: found automatically (PATH, Homebrew, /usr/bin).
#   --force          replace a status line command that something else set in tui.toml.
#                    Its old line is recorded, and uninstall.sh puts it back.
#
# Written for macOS's bash 3.2. Everything runs inside main(), which bash only starts once
# it has read the whole file: under `curl | bash`, nothing here can eat the rest of it.

REPO=infinitr0us/kimi-code-statusline-bash

say()  { printf '  %s\n' "$*"; }
warn() { if [[ -t 1 ]]; then printf '  \033[33m! %s\033[0m\n' "$*"; else printf '  ! %s\n' "$*"; fi; }
die()  { printf 'kimi-code-statusline-bash: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------- TOML and JSON, as far as needed ---
# (the same in uninstall.sh)
Q="'"
TABLE_RE='^[[:space:]]*\[[[:space:]]*(status_line|"status_line"|'$Q'status_line'$Q')[[:space:]]*][[:space:]]*(#.*)?$'
DOTTED_RE='^[[:space:]]*(status_line|"status_line"|'$Q'status_line'$Q')[[:space:]]*[.=]'
KEY_RE='^[[:space:]]*(command|"command"|'$Q'command'$Q')[[:space:]]*='
VALUE_RE=$KEY_RE'[[:space:]]*("(([^"\\]|\\.)*)"|'$Q'([^'$Q']*)'$Q')[[:space:]]*(#.*)?$'

utf8() { # $1 = code point -> REPLY = its UTF-8 bytes
  local c=$1 f
  if   (( c < 0x80 ));    then printf -v f '\\%03o' "$c"
  elif (( c < 0x800 ));   then printf -v f '\\%03o\\%03o' $(( 0xC0 | c >> 6 )) $(( 0x80 | (c & 0x3F) ))
  elif (( c < 0x10000 )); then printf -v f '\\%03o\\%03o\\%03o' $(( 0xE0 | c >> 12 )) $(( 0x80 | (c >> 6 & 0x3F) )) $(( 0x80 | (c & 0x3F) ))
  else printf -v f '\\%03o\\%03o\\%03o\\%03o' $(( 0xF0 | c >> 18 )) $(( 0x80 | (c >> 12 & 0x3F) )) $(( 0x80 | (c >> 6 & 0x3F) )) $(( 0x80 | (c & 0x3F) ))
  fi
  printf -v REPLY "$f"
}

unescape() { # $1 = the inside of a TOML basic string or JSON string -> REPLY = its value
  local s=$1 out= c n hex
  while [[ $s == *\\* ]]; do
    out+=${s%%\\*}; s=${s#*\\}
    c=${s:0:1} n=1
    case $c in
      b) out+=$'\b';; t) out+=$'\t';; n) out+=$'\n';; f) out+=$'\f';; r) out+=$'\r';; e) out+=$'\e';;
      u|U) if [[ $c == u ]]; then n=4; else n=8; fi
           hex=${s:1:n}
           if [[ ${#hex} -eq $n && $hex =~ ^[0-9A-Fa-f]+$ ]] && (( 16#$hex > 0 && 16#$hex <= 0x10FFFF )); then
             utf8 $(( 16#$hex )); out+=$REPLY; n=$(( n + 1 ))
           else out+="\\$c"; n=1; fi;;
      *) out+=$c;;   # \" \\ \/
    esac
    s=${s:n}
  done
  REPLY=$out$s
}

toml_command() { # $1 = a `command = ...` line -> REPLY = its string value; false for any other form
  [[ $1 =~ $VALUE_RE ]] || return 1
  if [[ ${BASH_REMATCH[2]:0:1} == "'" ]]; then REPLY=${BASH_REMATCH[5]}; else unescape "${BASH_REMATCH[3]}"; fi
}

json_str() { # $1 -> REPLY = $1 as a JSON string
  local s=${1//\\/\\\\} i o c u
  s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  if [[ $s == *[[:cntrl:]]* ]]; then   # the other control characters, as \u00XX
    for (( i = 1; i < 32; i++ )); do
      printf -v o '%03o' "$i"; printf -v c "\\$o"; printf -v u '\\u%04x' "$i"
      s=${s//$c/$u}
    done
  fi
  REPLY="\"$s\""
}

json_field() { # $1 = JSON text, $2 = key -> REPLY = its string value; false if absent or not a string
  local re='"'$2'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ $1 =~ $re ]] || return 1
  unescape "${BASH_REMATCH[1]}"
}

sh_quote() { # $1 -> REPLY = $1 as one word for sh
  if [[ $1 =~ ^[A-Za-z0-9_./+:@%,-]+$ ]]; then REPLY=$1; else REPLY="'${1//$Q/$Q\\$Q$Q}'"; fi
}

backup() { # $1 = file -> copied to <file>.bak-<date>-<time>, or -2, -3 .. if that is taken
  local b="$1.bak-$STAMP" n=2
  while [[ -e $b ]]; do b="$1.bak-$STAMP-$n"; n=$(( n + 1 )); done
  cp -p "$1" "$b" || die "could not back up $1, so it was left as it was."
  say "Backed up $1"
}

read_file() { # $1 = file -> REPLY = its content, byte for byte (but NULs); false if it exists but can't be read
  REPLY=
  [[ -e $1 ]] || return 0
  [[ -f $1 && -r $1 ]] || return 1
  IFS= read -r -d '' REPLY < "$1"
  return 0
}

# A file as LINES[i] and what ended each, SEPS[i] ("\r\n", "\n", or "" for the last), so a
# file with mixed line endings is written back as it was, but for the lines changed.
split_lines() { # $1 = text -> LINES, SEPS (the last line may be "": the text ended with a newline)
  local s=$1 l
  LINES=() SEPS=()
  while [[ $s == *$'\n'* ]]; do
    l=${s%%$'\n'*}; s=${s#*$'\n'}
    if [[ $l == *$'\r' ]]; then LINES+=("${l%$'\r'}"); SEPS+=($'\r\n'); else LINES+=("$l"); SEPS+=($'\n'); fi
  done
  LINES+=("$s"); SEPS+=('')
  local crlf=0 lf=0
  for s in "${SEPS[@]}"; do case $s in $'\r\n') crlf=$(( crlf + 1 ));; $'\n') lf=$(( lf + 1 ));; esac; done
  NL=$'\n'; (( crlf > lf )) && NL=$'\r\n'   # for lines that have no neighbor to follow
}

join_lines() { # LINES, SEPS -> REPLY = the text
  local i
  REPLY=
  for i in "${!LINES[@]}"; do REPLY+=${LINES[i]}${SEPS[i]}; done
}

insert_line() { # $1 = index, $2 = text: a line put before LINES[$1] (or at the end), ending like the one before it
  local k=$1 n=${#LINES[@]} sep=$NL
  (( k > 0 )) && [[ -n ${SEPS[k-1]} ]] && sep=${SEPS[k-1]}
  if (( k >= n )); then   # at the end: the old last line gets an end, the new one has none
    (( n > 0 )) && SEPS[n-1]=$sep
    LINES+=("$2"); SEPS+=('')
  else
    LINES=("${LINES[@]:0:k}" "$2" "${LINES[@]:k}"); SEPS=("${SEPS[@]:0:k}" "$sep" "${SEPS[@]:k}")
  fi
}

main() {
  local opt_version=latest opt_source= opt_home= opt_bash= opt_jq= opt_force=0
  while (( $# )); do
    case $1 in
      --version|--source|--kimi-home|--bash|--jq)
        (( $# >= 2 )) || die "$1 needs a value"
        case $1 in
          --version) opt_version=$2;; --source) opt_source=$2;; --kimi-home) opt_home=$2;;
          --bash) opt_bash=$2;; --jq) opt_jq=$2;;
        esac
        shift 2;;
      --force) opt_force=1; shift;;
      -h|--help)
        if [[ -r ${BASH_SOURCE[0]:-} ]]; then sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
        else echo "Options: --version TAG, --source PATH|URL, --kimi-home DIR, --bash PATH, --jq PATH, --force. See https://github.com/$REPO#install"
        fi
        exit 0;;
      *) die "unknown option $1 (see --help)";;
    esac
  done

  case $OSTYPE in
    darwin*) ;;
    msys*|cygwin*) die 'on Windows, run install.ps1 in PowerShell instead (see the README).';;
    *) die "this installer is for macOS (and install.ps1 for Windows); $OSTYPE is not supported.";;
  esac
  echo 'kimi-code-statusline-bash installer'

  # Nothing is written until every check below has passed.

  # ------------------------------------------------------------------ Kimi home ---
  local home=${opt_home:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}
  [[ -d $home ]] || die "Kimi Code's home folder $home does not exist. Install Kimi Code and start it once, or pass --kimi-home."
  home=$(CDPATH= cd -- "$home" && pwd) || die "cannot open $home"
  [[ $home == *[[:cntrl:]]* ]] && die "Kimi Code's home folder has a control character in its name."
  local app="$home/statusline-bash" tui="$home/tui.toml"
  local info="$home/statusline-bash/install.json"
  say "Kimi Code home: $home"

  # ----------------------------------------------------------------------- bash ---
  local bash=${opt_bash:-/bin/bash} ver
  [[ $bash == /* ]] || bash="$PWD/$bash"
  [[ -f $bash && -x $bash ]] || die "--bash $bash is not an executable file."
  [[ $bash == *[[:cntrl:]]* ]] && die "the path of bash has a control character in it."
  ver=$("$bash" --norc --noprofile -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"' 2>/dev/null)
  if ! [[ $ver =~ ^([0-9]+)\ ([0-9]+)$ ]] || (( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] < 302 )); then
    die "$bash is not bash 3.2 or newer (got '$ver')."
  fi
  say "bash: $bash (${ver/ /.})"

  # ------------------------------------------------------------------------- jq ---
  local jq= c
  if [[ -n $opt_jq ]]; then
    jq=$opt_jq; [[ $jq == /* ]] || jq="$PWD/$jq"
    [[ -f $jq && -x $jq ]] || die "--jq $jq is not an executable file."
  else
    for c in "$(command -v jq 2>/dev/null)" /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
      [[ $c == /* && -x $c ]] && "$c" -n 1 >/dev/null 2>&1 && { jq=$c; break; }
    done
  fi
  if [[ -n $jq ]]; then say "jq: $jq"
  else warn 'jq was not found: the quota, thinking effort and changed-lines parts stay empty. Install it with "brew install jq" (macOS 15 and later have it built in) and run this installer again.'
  fi

  # -------------------------------------------------------------- statusline.sh ---
  local src=$opt_source self=${BASH_SOURCE[0]:-} src_file tmp= script
  if [[ -z $src ]]; then
    # next to this file when run as one (a release zip or a clone), never under curl | bash
    if [[ -n $self && -f $self && -f $(dirname "$self")/statusline.sh ]]; then src="$(dirname "$self")/statusline.sh"
    elif [[ $opt_version == latest ]]; then src="https://github.com/$REPO/releases/latest/download/statusline.sh"
    else src="https://github.com/$REPO/releases/download/$opt_version/statusline.sh"
    fi
  fi
  if [[ $src =~ ^https?:// ]]; then
    say "Downloading $src"
    tmp=$(mktemp "${TMPDIR:-/tmp}/kimi-statusline.XXXXXX") || die 'cannot create a temporary file.'
    if ! curl -fsSL --retry 2 -o "$tmp" "$src"; then rm -f "$tmp"; die "could not download $src"; fi
    src_file=$tmp
  else
    src_file=$src
    [[ -f $src_file ]] || die "$src_file does not exist."
  fi
  read_file "$src_file" || { [[ -n $tmp ]] && rm -f "$tmp"; die "cannot read $src_file"; }
  script=$REPLY
  [[ -n $tmp ]] && rm -f "$tmp"
  script=${script#$'\xef\xbb\xbf'}
  script=${script//$'\r\n'/$'\n'}      # bash needs LF
  [[ $script == '#!'* && $script == *kimi-code-statusline-bash* ]] || die "$src is not kimi-code-statusline-bash's statusline.sh."
  local re=$'(^|\n)KSL_VERSION=([^[:space:]]+)' version=unknown
  [[ $script =~ $re ]] && version=${BASH_REMATCH[2]}

  # ------------------------------------------------------------------- tui.toml ---
  # Kimi runs the command as `sh -c <command>`: bash and the script, each quoted for sh
  # where it needs it, written as a TOML basic string.
  local command qb qs
  sh_quote "$bash"; qb=$REPLY
  sh_quote "$app/statusline.sh"; qs=$REPLY
  command="$qb $qs"
  local toml_value=${command//\\/\\\\}; toml_value=${toml_value//\"/\\\"}
  local new_line="command = \"$toml_value\""

  local raw bom=0 i
  read_file "$tui" || die "cannot read $tui, so it was left as it was."
  raw=$REPLY
  [[ $raw == $'\xef\xbb\xbf'* ]] && { bom=1; raw=${raw#$'\xef\xbb\xbf'}; }
  LINES=() SEPS=() NL=$'\n'
  [[ -n $raw ]] && split_lines "$raw"
  # Names spelled with escapes ("status\u005fline", "com\u006dand") are not read here:
  # refuse them rather than miss the status line command and add a second one.
  local esc_header_re='^[[:space:]]*\[[^]#]*\\' esc_key_re='^[[:space:]]*"[^"]*\\[^=]*='
  for i in "${!LINES[@]}"; do
    [[ ${LINES[i]} =~ $DOTTED_RE ]] &&
      die "$tui sets status_line in a form this installer does not edit (${LINES[i]}). Change it to a [status_line] table, or set $new_line there yourself."
    [[ ${LINES[i]} =~ $esc_header_re || ${LINES[i]} =~ $esc_key_re ]] &&
      die "$tui has a name spelled with escapes (${LINES[i]}), which this installer does not read. Write it plainly, or set $new_line under [status_line] yourself."
  done
  local header=-1 cmd_line=-1 current= have_current=0
  for i in "${!LINES[@]}"; do [[ ${LINES[i]} =~ $TABLE_RE ]] && { header=$i; break; }; done
  if (( header >= 0 )); then
    for (( i = header + 1; i < ${#LINES[@]}; i++ )); do
      [[ ${LINES[i]} =~ ^[[:space:]]*\[ ]] && break
      [[ ${LINES[i]} =~ $KEY_RE ]] && { cmd_line=$i; break; }
    done
  fi
  if (( cmd_line >= 0 )); then
    toml_command "${LINES[cmd_line]}" || die "Could not read the status line command in $tui: ${LINES[cmd_line]}"
    current=$REPLY
    [[ -n $current ]] && have_current=1
  fi

  # what to put back on uninstall: the line this replaced, and whether the table is ours
  local old= old_command= prev_line= prev_command= created=false has_prev_line=0 has_prev_command=0 had_info=0
  read_file "$info" || die "cannot read $info"
  old=$REPLY
  [[ -f $info ]] && had_info=1
  json_field "$old" command && old_command=$REPLY
  if (( have_current )) && [[ $current == "$command" || ( -n $old_command && $current == "$old_command" ) ]]; then
    json_field "$old" previousLine && { prev_line=$REPLY; has_prev_line=1; }
    json_field "$old" previousCommand && { prev_command=$REPLY; has_prev_command=1; }
    [[ $old =~ \"createdTable\"[[:space:]]*:[[:space:]]*true ]] && created=true
  elif (( have_current )); then
    (( opt_force )) || die "tui.toml already runs another status line command: $current
Run this installer with --force to replace it; uninstall.sh puts it back."
    prev_line=${LINES[cmd_line]} has_prev_line=1 prev_command=$current has_prev_command=1
    say "Replacing the status line command $current"
  else
    (( cmd_line >= 0 )) && { prev_line=${LINES[cmd_line]}; has_prev_line=1; }   # command = "" stays as it was
    (( header < 0 )) && created=true
  fi

  if (( cmd_line >= 0 )); then
    LINES[cmd_line]=$new_line
  elif (( header >= 0 )); then
    insert_line $(( header + 1 )) "$new_line"
  else   # a [status_line] table of its own at the end, after an empty line
    local n=${#LINES[@]}
    if (( n == 0 )); then
      insert_line 0 '[status_line]'; insert_line 1 "$new_line"; insert_line 2 ''
    elif [[ -z ${LINES[n-1]} ]]; then   # (the file ends with a newline: the table goes before it)
      insert_line $(( n - 1 )) ''; insert_line $n '[status_line]'; insert_line $(( n + 1 )) "$new_line"
    else                                # (no newline at the end, and none added)
      insert_line $n ''; insert_line $(( n + 1 )) '[status_line]'; insert_line $(( n + 2 )) "$new_line"
    fi
  fi
  local new_raw
  join_lines; new_raw=$REPLY

  # ---------------------------------------------------------------------- write ---
  local changed=0
  [[ $new_raw != "$raw" ]] && changed=1
  if (( changed )); then   # (tui.toml is written last, so find out now whether it can be)
    if [[ -e $tui ]]; then [[ -w $tui ]] || die "cannot write $tui, so nothing was changed."
    else [[ -w $home ]] || die "cannot create $tui, so nothing was changed."; fi
  fi
  STAMP=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$app" || die "cannot create $app"
  replace_file() { # $1 = file, $2 = content: written whole through <file>.tmp, keeping the old file's permissions
    printf '%s' "$2" > "$1.tmp" && { [[ ! -f $1 ]] || chmod "$(stat -f %Lp "$1")" "$1.tmp"; } &&
      mv -f "$1.tmp" "$1" || { rm -f "$1.tmp"; return 1; }
  }
  write_kept() { # $1 = file, $2 = content: writes it, first backing up a different old one
    if [[ -f $1 ]]; then
      read_file "$1" || die "cannot read $1"
      [[ $REPLY == "$2" ]] && return 0
      backup "$1"
    fi
    replace_file "$1" "$2" || die "cannot write $1"
  }
  write_kept "$app/statusline.sh" "$script"
  chmod 755 "$app/statusline.sh"
  # jq's path goes in a file that statusline.sh reads, as the shell Kimi starts may not
  # have your PATH
  if [[ -n $jq ]]; then write_kept "$app/jq-path.txt" "$jq"$'\n'
  else rm -f "$app/jq-path.txt"; fi

  (( changed )) && [[ -f $tui ]] && backup "$tui"
  # install.json goes before tui.toml, and back to what it was should tui.toml fail after
  # all: so it always tells of the command tui.toml runs, which is what uninstall puts back.
  local j_cmd j_pc=null j_pl=null version_json now json
  json_str "$command"; j_cmd=$REPLY
  (( has_prev_command )) && { json_str "$prev_command"; j_pc=$REPLY; }
  (( has_prev_line )) && { json_str "$prev_line"; j_pl=$REPLY; }
  json_str "$version"; version_json=$REPLY
  now=$(date +%Y-%m-%dT%H:%M:%S%z)
  printf -v json '{\n  "version": %s,\n  "installedAt": "%s",\n  "command": %s,\n  "previousCommand": %s,\n  "previousLine": %s,\n  "createdTable": %s\n}\n' \
    "$version_json" "$now" "$j_cmd" "$j_pc" "$j_pl" "$created"
  replace_file "$info" "$json" || die "cannot write $info, so tui.toml was left as it was."
  if (( changed )); then
    # in place, so tui.toml keeps its permissions
    if ! { (( bom )) && printf '\xef\xbb\xbf'; printf '%s' "$new_raw"; } > "$tui"; then
      if (( had_info )); then replace_file "$info" "$old"; else rm -f "$info"; fi
      die "cannot write $tui (see its backup), so install.json was put back as it was."
    fi
  fi
  say "tui.toml: [status_line] $new_line"

  # ----------------------------------------------------------------- smoke test ---
  # One run the way Kimi does it: sh -c <command>, the JSON snapshot on stdin, the first
  # stdout line used. (/usr/bin/time: bash 3.2 cannot time a run in milliseconds.)
  local payload out_file time_file pid code line ms=
  json_str "$HOME"
  payload='{"model":"Kimi","cwd":'$REPLY',"gitBranch":null,"permissionMode":"yolo","planMode":false,"sessionId":null}'
  out_file=$(mktemp "${TMPDIR:-/tmp}/kimi-statusline.XXXXXX") && time_file=$(mktemp "${TMPDIR:-/tmp}/kimi-statusline.XXXXXX") ||
    die 'cannot create a temporary file.'
  ( printf '%s' "$payload" | KIMI_CODE_HOME=$home KIMI_CODE_STATUS_LINE=1 /usr/bin/time -p sh -c "$command" > "$out_file" 2> "$time_file" ) &
  pid=$!
  for (( i = 0; i < 50; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
  wait "$pid"; code=$?
  IFS= read -r line < "$out_file"
  [[ $(< "$time_file") =~ real[[:space:]]+([0-9]+)\.([0-9]{2}) ]] && ms=$(( 10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]} * 10 ))
  rm -f "$out_file" "$time_file"
  if (( code == 0 )) && [[ -n $line ]]; then
    [[ -t 1 ]] || line=$(printf '%s' "$line" | sed $'s/\x1b\\[[0-9;]*m//g')
    if [[ -z $ms ]]; then say 'Test run:'
    elif (( ms < 10 )); then say 'Test run (under 10 ms):'
    else say "Test run ($ms ms):"; fi
    printf '    %s\n' "$line"
    [[ -n $ms ]] && (( ms > 300 )) && warn 'That run took over 300 ms, the limit after which Kimi drops a run. A first run is slower; if Kimi keeps showing its own footer, see Troubleshooting in the README.'
  else
    warn 'The test run printed nothing. See Troubleshooting in the README.'
  fi

  echo
  echo "Installed kimi-code-statusline-bash $version into $app"
  echo 'Next: run /reload-tui in Kimi Code (or restart it). The icons need a Nerd Font in your terminal.'
}

main "$@"
