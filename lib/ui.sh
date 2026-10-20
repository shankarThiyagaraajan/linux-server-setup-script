# shellcheck shell=bash
# ui.sh: terminal UI building blocks for the Control Room look.
# Arrow-key menus, checklists, prompts and pop-up boxes, using plain ANSI
# escapes so nothing extra has to be installed.

ui_interactive() { [[ $SS_ASSUME_YES != true && $SS_TTY == true ]]; }

# Size from the terminal itself: stdout may be a pipe into the log.
ui_size()  { stty size </dev/tty 2>/dev/null || echo "32 100"; }
ui_cols()  { local l c; read -r l c < <(ui_size); (( c > 20 )) || c=100; echo "$c"; }
ui_lines() { local l c; read -r l c < <(ui_size); (( l > 10 )) || l=32; echo "$l"; }
rep() { local i out=""; for (( i = 0; i < $2; i++ )); do out+=$1; done; printf '%s' "$out"; }
ui_clear() { printf '\e[H\e[2J'; }
ui_goto()  { printf '\e[%d;%dH' "$1" "$2"; }
ui_hide_cursor() { printf '\e[?25l'; }
ui_show_cursor() { printf '\e[?25h'; }

# Visible length of a string (ignores colour codes; counts characters, not bytes).
ui_len() { local s; s=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' <<<"$1"); printf '%d' "${#s}"; }

# ui_pad TEXT WIDTH: pad or cut to an exact visible width.
ui_pad() {
  local t=$1 w=$2 n
  n=$(ui_len "$t")
  if (( n > w )); then
    t=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' <<<"$t"); t="${t:0:w-1}…"; n=$w
  fi
  printf '%s%*s' "$t" $(( w - n )) ''
}

# ui_key: read one key; prints up, down, left, right, enter, space, esc, tab
# or the character. ui_key_wait SECONDS prints "timeout" if nothing is pressed.
ui_key_wait() { UI_KEY_TIMEOUT=$1 ui_key; }
ui_key() {
  local k k2="" rc=0
  if [[ -n ${UI_KEY_TIMEOUT:-} ]]; then
    IFS= read -rsn1 -t "$UI_KEY_TIMEOUT" k </dev/tty || rc=$?
    (( rc > 128 )) && { echo timeout; return; }
    (( rc == 0 )) || { echo esc; return; }
  else
    IFS= read -rsn1 k </dev/tty || { echo esc; return; }
  fi
  case $k in
    $'\e') IFS= read -rsn2 -t 0.05 k2 </dev/tty || true
            case $k2 in '[A') echo up ;; '[B') echo down ;; '[C') echo right ;; '[D') echo left ;; *) echo esc ;; esac ;;
    '')     echo enter ;;
    ' ')    echo space ;;
    $'\t')  echo tab ;;
    *)      printf '%s\n' "$k" ;;
  esac
}

# ui_input VAR "Prompt" [default]
ui_input() {
  local __v=$1 __p=$2 __d=${3:-} __r=""
  ui_show_cursor
  IFS= read -rep "  $__p${__d:+ ${C_DIM}[$__d]${C_0}}: " __r </dev/tty || __r=""
  printf -v "$__v" '%s' "${__r:-$__d}"
}

# ui_secret VAR "Prompt": asks twice; blank allowed (caller decides what that means).
ui_secret() {
  local __v=$1 __p=$2 a b
  while true; do
    IFS= read -rsp "  $__p: " a </dev/tty; echo
    [[ -z $a ]] && { printf -v "$__v" ''; return 0; }
    IFS= read -rsp "  Repeat: " b </dev/tty; echo
    [[ $a == "$b" ]] && { printf -v "$__v" '%s' "$a"; return 0; }
    warn "They don't match, try again."
  done
}

# ui_confirm "Question" [y|n default]
ui_confirm() {
  local a d=${2:-n}
  ui_show_cursor
  IFS= read -rep "  $1 $( [[ $d == y ]] && echo '[Y/n]' || echo '[y/N]') " a </dev/tty || a=""
  a=${a:-$d}
  [[ ${a,,} == y* ]]
}

# ui_menu TITLE ITEM... : items are "Label|hint". Result index in UI_CHOICE (-1 = back).
# Draws in place at the current cursor row.
ui_menu() {
  local title=$1; shift
  local items=("$@") sel=0 i key label hint n=$#
  UI_CHOICE=-1
  ui_hide_cursor
  printf '\n  %s%s%s\n' "$C_CYAN$C_BOLD" "$title" "$C_0"
  while true; do
    for i in "${!items[@]}"; do
      label=${items[$i]%%|*}; hint=${items[$i]#*|}; [[ $hint == "${items[$i]}" ]] && hint=""
      if (( i == sel )); then
        printf '\e[2K  %s› %s%s  %s%s\n' "$C_INV$C_CYAN" "$(ui_pad "$label" "${UI_MENU_WIDTH:-34}")" "$C_0" "$hint" "$C_0"
      else
        printf '\e[2K    %s  %s%s%s\n' "$(ui_pad "$label" "${UI_MENU_WIDTH:-34}")" "$C_DIM" "$hint" "$C_0"
      fi
    done
    printf '\e[2K  %s↑/↓ move · enter select · esc back%s\n' "$C_DIM" "$C_0"
    key=$(ui_key)
    case $key in
      up)    sel=$(( (sel - 1 + n) % n )) ;;
      down)  sel=$(( (sel + 1) % n )) ;;
      enter) UI_CHOICE=$sel; break ;;
      esc|q) UI_CHOICE=-1; break ;;
      [1-9]) if (( key <= n )); then UI_CHOICE=$((key - 1)); break; fi ;;
    esac
    printf '\e[%dA' $(( n + 1 ))
  done
  ui_show_cursor
}

# ui_checklist TITLE ITEM... : items are "on|Label|hint" or "off|Label|hint".
# Result: UI_CHECKED array of selected indices. Returns 1 if cancelled.
ui_checklist() {
  local title=$1; shift
  local items=("$@") sel=0 i key n=$# mark state label hint
  local -a on=()
  for i in "${!items[@]}"; do [[ ${items[$i]%%|*} == on ]] && on[$i]=1 || on[$i]=0; done
  ui_hide_cursor
  printf '\n  %s%s%s\n' "$C_CYAN$C_BOLD" "$title" "$C_0"
  while true; do
    for i in "${!items[@]}"; do
      state=${items[$i]#*|}; label=${state%%|*}; hint=${state#*|}
      (( on[i] )) && mark="${C_GREEN}[x]${C_0}" || mark="[ ]"
      if (( i == sel )); then
        printf '\e[2K  %s›%s %s %s%s%s  %s%s%s\n' "$C_CYAN" "$C_0" "$mark" "$C_BOLD" "$(ui_pad "$label" 30)" "$C_0" "$C_DIM" "$hint" "$C_0"
      else
        printf '\e[2K    %s %s  %s%s%s\n' "$mark" "$(ui_pad "$label" 30)" "$C_DIM" "$hint" "$C_0"
      fi
    done
    printf '\e[2K  %s↑/↓ move · space tick/untick · enter done · esc cancel%s\n' "$C_DIM" "$C_0"
    key=$(ui_key)
    case $key in
      up)    sel=$(( (sel - 1 + n) % n )) ;;
      down)  sel=$(( (sel + 1) % n )) ;;
      space) on[sel]=$(( 1 - on[sel] )) ;;
      enter) break ;;
      esc)   ui_show_cursor; return 1 ;;
    esac
    printf '\e[%dA' $(( n + 1 ))
  done
  UI_CHECKED=()
  for i in "${!items[@]}"; do (( on[i] )) && UI_CHECKED+=("$i"); done
  ui_show_cursor
  return 0
}

# ui_popup COLOR TITLE BODY_LINE... -- ITEM... : a framed box drawn over the
# screen centre, with a menu at the bottom. Items are "Label|hint".
# Result index in UI_CHOICE (-1 = esc).
ui_popup() {
  local color=$1 title=$2; shift 2
  local body=() items=() seen=0 a
  for a in "$@"; do
    if [[ $a == -- ]]; then seen=1; continue; fi
    if (( seen )); then items+=("$a"); else body+=("$a"); fi
  done
  local cols lines w h top left sel=0 n=${#items[@]} i key row label hint
  cols=$(ui_cols); lines=$(ui_lines)
  w=$(( cols - 6 )); (( w > 100 )) && w=100
  # Wrap long plain lines (coloured ones are kept as they are).
  local wrapped=()
  for a in "${body[@]}"; do
    if (( $(ui_len "$a") > w - 4 )) && [[ $a != *$'\e'* ]]; then
      mapfile -t -O "${#wrapped[@]}" wrapped < <(fold -s -w $(( w - 4 )) <<<"$a" | sed 's/ *$//')
    else wrapped+=("$a"); fi
  done
  body=("${wrapped[@]}")
  h=$(( ${#body[@]} + n + 6 ))
  top=$(( (lines - h) / 2 )); (( top < 1 )) && top=1
  left=$(( (cols - w) / 2 + 1 ))
  UI_CHOICE=-1
  ui_hide_cursor
  while true; do
    row=$top
    ui_goto "$row" "$left"; printf '%s╔%s╗%s' "$color" "$(rep ═ $((w - 2)))" "$C_0"
    ui_goto "$row" $(( left + 2 )); printf '%s%s %s %s' "$color" "$C_BOLD" "$title" "$C_0"
    for a in "" "${body[@]}" ""; do
      row=$((row + 1)); ui_goto "$row" "$left"
      printf '%s║%s %s %s║%s' "$color" "$C_0" "$(ui_pad "$a" $((w - 4)))" "$color" "$C_0"
    done
    for i in "${!items[@]}"; do
      row=$((row + 1)); ui_goto "$row" "$left"
      label=${items[$i]%%|*}; hint=${items[$i]#*|}
      if (( i == sel )); then
        printf '%s║%s %s %s║%s' "$color" "$C_0" "$C_INV$C_CYAN$(ui_pad "› $label   $hint" $((w - 4)))$C_0" "$color" "$C_0"
      else
        printf '%s║%s %s %s║%s' "$color" "$C_0" "$(ui_pad "  $label   $C_DIM$hint$C_0" $((w - 4)))" "$color" "$C_0"
      fi
    done
    row=$((row + 1)); ui_goto "$row" "$left"
    printf '%s║%s %s %s║%s' "$color" "$C_0" "$(ui_pad "${C_DIM}${UI_POPUP_NOTE-Nothing changes until you confirm the plan. }↑/↓ move · enter select · esc close$C_0" $((w - 4)))" "$color" "$C_0"
    row=$((row + 1)); ui_goto "$row" "$left"
    printf '%s╚%s╝%s' "$color" "$(rep ═ $((w - 2)))" "$C_0"
    key=$(ui_key)
    case $key in
      up)    sel=$(( (sel - 1 + n) % n )) ;;
      down)  sel=$(( (sel + 1) % n )) ;;
      enter) UI_CHOICE=$sel; break ;;
      esc)   break ;;
    esac
  done
  ui_goto "$(ui_lines)" 1
  ui_show_cursor
}

ui_pause() { ui_interactive || return 0; printf '\n  %sPress any key to go back%s' "$C_DIM" "$C_0"; ui_key >/dev/null; }
