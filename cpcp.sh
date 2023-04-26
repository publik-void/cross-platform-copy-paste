#!/bin/sh

# CPCP – cross platform copy paste

set -e
#set -eu

subcommands="copy paste dry"
locations="auto local remote both dry"
backends="auto pbcopy pbpaste reattach-to-user-namespace xsel xclip nc osc52 \
  tmux tmp dry"

tmp_file_path="/tmp/cpcp-tmp-clipboard-u$(id -u)-g$(id -g)"

print_usage() {
  msg="Usage:
  $0 \\
    [$(printf %s "$subcommands" | tr " " "|")] \\
    [$(printf %s "$locations" | tr " " "|")] \\
    [$(printf %s "$backends" | tr " " "|")] \\
    [files...]

  For the copy commands, stdin and any input files will be concatenated together
  to form the input."

  printf "%s\n" "$msg"
}

print_nonexistent_combination() {
  msg="$0: combination of arguments $1 $2 $3 is not available"

  printf "%s\n" "$msg" >&2
}

one_of() {
  word="$1"
  shift 1
  [ $# -le 0 ] && return 1
  [ "$word" = "$1" ] && return 0
  shift 1
  one_of $word $@
}

has() {
  type "$1" &>/dev/null
}

is_tty() {
  tty &>/dev/null
}

is_ssh_session() {
  [ "$SSH_CLIENT" ] && [ "$SSH_TTY" ]
}

is_tmux_session() {
  [ "$TMUX" ]
}

get_backend() {
  if [ $# -le 0 ]; then
    printf "%s\n" "$0: no suitable backend could be found" >&2
    return 2
  fi
  backend="$1"
  if ([ "$backend" = "bpcopy" ] && has pbcopy && has pbpaste) || \
     ([ "$backend" = "reattach-to-user-namespace" ] && has \
       reattach-to-user-namespace) || \
     ([ "$backend" = "xsel" ] && has xsel && [ -n "${DISPLAY-}" ]) || \
     ([ "$backend" = "xclip" ] && has xclip && [ -n "${DISPLAY-}" ]) || \
     ([ "$backend" = "nc" ] && has nc && [ "$cpcp_remote_tunnel_port" ]) || \
     ([ "$backend" = "osc52" ]) || \
     ([ "$backend" = "tmux" ] && has tmux && is_tmux_session) || \
     ([ "$backend" = "tmp" ]); then
    printf %s "$backend"
  else
    shift 1
    get_backend $@
  fi
}

osc52_encode() {
  data=$(cat $@)

  # The maximum length of an OSC 52 escape sequence is 100_000 bytes, of which
  # 7 bytes are occupied by a "\033]52;c;" header, 1 byte by a "\a" footer, and
  # 99_992 bytes by the base64-encoded result of 74_994 bytes of copyable text
  max_length=74994
  data_length=$(printf %s "$data" | wc -c)

  # Warn if max_length is exceeded
  if [ "$data_length" -gt "$max_length" ]; then
    printf "$0: osc52: input is %d bytes too long\n" \
      "$(( data_length - max_length ))" >&2
  fi

  # Build up OSC 52 ANSI escape sequence
  esc="$(printf %s "$data" | head -c $max_length | base64 | tr -d '\r\n')"
  esc="\033]52;c;$esc\a"

  #if is_tmux_session; then
  #  esc="\033Ptmux;\033$esc\033\\"
  #fi

  printf "%s" "$esc"
}

local_tty() {
  target_tty=""
  if is_tmux_session; then
    target_tty=$(tmux list-panes -F "#{pane_active} #{pane_tty}" | \
      sed -n -e 's/^1 /\1/p')
  elif is_tty; then
    target_tty=$(tty)
  fi
  [ -c "$target_tty" ] || target_tty="/dev/null"
  printf "%s" "$target_tty"
}

remote_tty() {
  if is_ssh_session; then
    target_tty="$SSH_TTY"
  fi
  [ -c "$target_tty" ] || target_tty="/dev/null"
  printf "%s" "$target_tty"
}

default_subcommand="copy"
default_location="auto"
default_backend="auto"

if [ "$#" -le 0 ]; then
  subcommand="$default_subcommand"
else
  subcommand="$1"
  one_of "$subcommand" $subcommands "drycopy" "drypaste" || \
    (print_usage; return 1)
  shift 1
fi

if [ "$#" -le 0 ]; then
  location="$default_location"
else
  location="$1"
  one_of "$location" $locations || (print_usage; return 1)
  shift 1
fi

if [ "$#" -le 0 ]; then
  backend="$default_backend"
else
  backend="$1"
  one_of "$backend" $backends || (print_usage; return 1)
  shift 1
fi

dry="false"; verbose="false"

if [ "$subcommand" = "dry" ] || [ "$subcommand" = "drycopy" ] || \
   [ "$subcommand" = "drypaste" ] || [ "$location" = "dry" ] || \
   [ "$backend" = "dry" ]; then
  dry="true"; verbose="true"
  [ "$subcommand" = "dry" ] && subcommand="auto"
  [ "$subcommand" = "drycopy" ] && subcommand="copy"
  [ "$subcommand" = "drypaste" ] && subcommand="paste"
  [ "$location" = "dry" ] && location="auto"
  [ "$backend" = "dry" ] && backend="auto"
fi

[ "$subcommand" = "auto" ] && subcommand="copy"

if [ "$location" = "auto" ]; then
  if [ "$subcommand" = "copy" ]; then
    if is_ssh_session; then
      location="both"
    else
      location="local"
    fi
  elif [ "$subcommand" = "paste" ]; then
    location="local"
  fi
fi

if [ "$location" = "both" ]; then
  if [ "$dry" = "true" ]; then
    [ "$subcommand" = "auto" ] && subcommand="dry"
    [ "$subcommand" = "copy" ] && subcommand="drycopy"
    [ "$subcommand" = "paste" ] && subcommand="drypaste"
  fi
  $0 "$subcommand" "local"  "$backend" $@ || return $?
  $0 "$subcommand" "remote" "$backend" $@ || return $?
  return 0
fi

if [ "$backend" = "auto" ]; then
  if [ "$subcommand" = "copy" ]; then
    if [ "$location" = "local" ]; then
      backend=$(get_backend pbcopy reattach-to-user-namespace xsel xclip tmux \
        tmp osc52)
    elif [ "$location" = "remote" ]; then
      backend=$(get_backend nc osc52)
    fi
  elif [ "$subcommand" = "paste" ]; then
    if [ "$location" = "local" ]; then
      backend=$(get_backend pbcopy reattach-to-user-namespace xsel xclip tmux \
        tmp)
    elif [ "$location" = "remote" ]; then
      backend=$(get_backend)
    fi
  fi
fi

[ "$backend" = "pbpaste" ] && backend="pbcopy"

[ "$backend" ] || return 2

[ "$verbose" = "true" ] && \
  printf "%s\n" "$0 $subcommand $location $backend $@"

command=""

if [ "$subcommand" = "copy" ]; then
  data=$(cat "$@")
  if [ "$location" = "local" ]; then
    case "$backend" in
      "pbcopy") command="pbcopy" ;;
      "reattach-to-user-namespace") command="reattach-to-user-namespace pbcopy"
        ;;
      "xsel") command="xsel -i --clipboard" ;;
      "xclip")
        command="xclip -i -f -selection primary | xclip -i -selection clipboard"
        ;;
      "nc") command="nc localhost $cpcp_remote_tunnel_port" ;;
      "osc52") command="osc52_encode > $(local_tty)" ;;
      "tmux") command="tmux load-buffer -" ;;
      "tmp") command="tee $tmp_file_path &>/dev/null" ;;
    esac
  elif [ "$location" = "remote" ]; then
    case "$backend" in
      "osc52") command="osc52_encode > $(remote_tty)" ;;
    esac
  fi
elif [ "$subcommand" = "paste" ]; then
  if [ "$location" = "local" ]; then
    case "$backend" in
      "pbcopy") command="pbpaste" ;;
      "reattach-to-user-namespace") command="reattach-to-user-namespace pbpaste"
        ;;
      "xsel") command="xsel -o --clipboard" ;;
      "xclip") command="xclip -o -selection clipboard" ;;
      "tmux") command="tmux save-buffer -" ;;
      "tmp") command="[ -f $tmp_file_path ] && cat $tmp_file_path" ;;
    esac
  elif [ "$location" = "remote" ]; then
    case "$backend" in
      *) ;;
    esac
  fi
fi

if [ "$command" ]; then
  if [ "$verbose" = "true" ]; then
    printf "backend command is: %s\n" "$command"
  fi
  if [ "$dry" = "false" ]; then
    [ "$subcommand" = "copy" ] && (printf "%s" "$data" | eval "$command")
    [ "$subcommand" = "paste" ] && eval $command
  fi
else
  print_nonexistent_combination "$subcommand" "$location" "$backend"
  return 3
fi

