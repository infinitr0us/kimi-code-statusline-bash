#!/usr/bin/env bash
# Removes kimi-code-statusline-bash from Kimi Code on macOS.
# https://github.com/infinitr0us/kimi-code-statusline-bash (MIT license)
#
# Takes the [status_line] command out of <Kimi home>/tui.toml, or puts back the line that
# install.sh --force replaced, then deletes the installed files and the status line's
# cache. Backups made by install.sh stay where they are. <Kimi home> is KIMI_CODE_HOME,
# else ~/.kimi-code.
#     curl -fsSL https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/uninstall.sh | bash
#
# Options (after `bash -s --` when piped from curl):
#   --kimi-home DIR  Kimi Code's home folder. Default: KIMI_CODE_HOME, else ~/.kimi-code.

say() { printf '  %s\n' "$*"; }
die() { printf 'kimi-code-statusline-bash: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------- TOML and JSON, as far as needed ---
# (the same as in install.sh)
Q="'"
TABLE_RE='^[[:space:]]*\[[[:space:]]*(status_line|"status_line"|'$Q'status_line'$Q')[[:space:]]*][[:space:]]*(#.*)?$'
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
  cp -p "$1" "$b" && say "Backed up $1"
}

read_file() { # $1 = file -> REPLY = its content, byte for byte (but NULs)
  REPLY=
  [[ -f $1 ]] && IFS= read -r -d '' REPLY < "$1"
  return 0
}

split_lines() { # $1 = text -> LINES = its lines, without \r\n or \n; the last one may be ""
  local s=$1 l
  LINES=()
  while [[ $s == *$'\n'* ]]; do
    l=${s%%$'\n'*}; LINES+=("${l%$'\r'}"); s=${s#*$'\n'}
  done
  LINES+=("${s%$'\r'}")
}

main() {
  local opt_home=
  while (( $# )); do
    case $1 in
      --kimi-home) (( $# >= 2 )) || die "$1 needs a value"; opt_home=$2; shift 2;;
      -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null ||
                   echo 'See https://github.com/infinitr0us/kimi-code-statusline-bash#uninstall'; exit 0;;
      *) die "unknown option $1 (see --help)";;
    esac
  done
  case $OSTYPE in
    darwin*) ;;
    msys*|cygwin*) die 'on Windows, run uninstall.ps1 in PowerShell instead (see the README).';;
    *) die "this uninstaller is for macOS (and uninstall.ps1 for Windows); $OSTYPE is not supported.";;
  esac
  echo 'kimi-code-statusline-bash uninstaller'

  local home=${opt_home:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}
  [[ -d $home ]] || die "Kimi Code's home folder $home does not exist."
  home=$(CDPATH= cd -- "$home" && pwd) || die "cannot open $home"
  local app="$home/statusline-bash" tui="$home/tui.toml"
  local info= recorded=
  read_file "$app/install.json"; info=$REPLY
  json_field "$info" command && recorded=$REPLY
  # the command install.sh writes by default (for an install.json gone missing)
  local default
  sh_quote "$app/statusline.sh"; default="/bin/bash $REPLY"

  # ------------------------------------------------------------------- tui.toml ---
  if [[ -f $tui ]]; then
    local raw bom=0 nl=$'\n' i
    read_file "$tui"; raw=$REPLY
    [[ $raw == $'\xef\xbb\xbf'* ]] && { bom=1; raw=${raw#$'\xef\xbb\xbf'}; }
    [[ $raw == *$'\r\n'* ]] && nl=$'\r\n'
    split_lines "$raw"
    local lines=("${LINES[@]}")
    local header=-1 cmd_line=-1 end=${#lines[@]} current= have_current=0
    for i in "${!lines[@]}"; do [[ ${lines[i]} =~ $TABLE_RE ]] && { header=$i; break; }; done
    if (( header >= 0 )); then
      for (( i = header + 1; i < ${#lines[@]}; i++ )); do
        [[ ${lines[i]} =~ ^[[:space:]]*\[ ]] && { end=$i; break; }
        (( cmd_line < 0 )) && [[ ${lines[i]} =~ $KEY_RE ]] && cmd_line=$i
      done
    fi
    (( cmd_line >= 0 )) && toml_command "${lines[cmd_line]}" && { current=$REPLY; have_current=1; }
    if (( have_current )) && [[ $current == "$default" || ( -n $recorded && $current == "$recorded" ) ]]; then
      local prev=
      json_field "$info" previousLine && prev=$REPLY
      if [[ -n $prev ]]; then
        lines[cmd_line]=$prev
        say "tui.toml: put back $prev"
      else
        # drop the line, and the [status_line] table too if install.sh added it and
        # nothing else is in it now
        local empty=0 kept=()
        [[ $info =~ \"createdTable\"[[:space:]]*:[[:space:]]*true ]] && empty=1
        for (( i = header + 1; empty && i < end; i++ )); do
          (( i == cmd_line )) && continue
          [[ ${lines[i]} =~ ^[[:space:]]*(#.*)?$ ]] || empty=0
        done
        for i in "${!lines[@]}"; do
          (( i == cmd_line )) && continue
          (( empty && i >= header && i < end )) && continue
          kept+=("${lines[i]}")
        done
        lines=("${kept[@]}")
        say 'tui.toml: removed the status line command; Kimi Code shows its own footer again'
      fi
      STAMP=$(date +%Y%m%d-%H%M%S)
      backup "$tui"
      local out= first=1
      for i in "${!lines[@]}"; do
        if (( first )); then out=${lines[i]}; first=0; else out+=$nl${lines[i]}; fi
      done
      { (( bom )) && printf '\xef\xbb\xbf'; printf '%s' "$out"; } > "$tui" || die "cannot write $tui"
    elif (( cmd_line >= 0 )); then
      say "tui.toml runs another status line command; left it alone: ${lines[cmd_line]}"
    fi
  fi

  # ---------------------------------------------------------------------- files ---
  local name
  for name in statusline.sh jq-path.txt install.json; do rm -f "$app/$name"; done
  if [[ -d $app ]]; then
    if [[ -n $(ls -A "$app") ]]; then say "Kept the backups in $app"; else rmdir "$app"; fi
  fi
  # the cache; a background worker may still hold a file for a moment
  rm -rf "$home/cache/statusline" 2>/dev/null

  echo
  echo 'Removed kimi-code-statusline-bash. Run /reload-tui in Kimi Code (or restart it).'
}

main "$@"
