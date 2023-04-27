#!/bin/sh

# CPCP – cross platform copy paste

set -e
#set -eu

subcommands="copy paste"
locations="auto local remote both"
backends="auto pbcopy pbpaste reattach-to-user-namespace xsel xclip nc osc52 \
tmux fifo shm tmp"

default_subcommand="copy"
default_location="auto"
default_backend="auto"

print_usage() {
  msg="Usage:
  $0 [--dry] [--verbose] \\
    [$(printf %s "$subcommands" | tr " " "|")] \\
    [$(printf %s "$locations" | tr " " "|")] \\
    [$(printf %s "$backends" | tr " " "|")] \\
    [files...]

Notes:
  The default subcommand, location, and backend are $default_subcommand, \
$default_location, and $default_backend, respectively.

  The default for files is -, i.e. stdin/stdout.

  The environment variable CPCP_REMOTE_TUNNEL_PORT has to be set for the nc \
backend to be available.

  The environment variable CPCP_BUFFER_FILE_DIRNAME can be set to use a custom \
directory for the fifo, shm (if filesystem is in-memory), and tmp backends."

  printf "%s\n" "$msg"
}

print_nonexistent_combination() {
  msg="$0: combination of arguments $1 $2 $3 is not available"

  printf "%s\n" "$msg" >&2
}

is() { [ "$1" = "true" ]; }

has() { type "$1" 1> /dev/null; }

one_of() (
  word="$1"
  shift 1
  [ $# -le 0 ] && return 1
  [ "$word" = "$1" ] && return 0
  shift 1
  one_of $word $@
)

# This only works if stdin doesn't come from a redirection, so of limited value
is_tty() { tty 2> /dev/null; }

is_ssh_session() { [ "$SSH_CLIENT" ] && [ "$SSH_TTY" ]; }

is_tmux_session() { [ "$TMUX" ]; }

is_fs() {
  fs="$1"; file="$2"
  df_output=$(df -P -t "$fs" "$file" 2> /dev/null) || return 1
  df_output=$(printf "%s" "$df_output" | sed -e '/^Filesystem/d')
  [ "$df_output" ]
}

is_ram() {
  file="$1"; backend="shm"; [ $# -le 1 ] || backend="$2"
  if [ "$backend" = "shm" ]; then
    is_fs "tmpfs" "$file" && return 0
    is_fs "ramfs" "$file" && return 0
    is_fs "shm" "$file" && return 0
    return 1
  fi
}

is_suited_buffer_file_dir() {
  file="$1"; backend="$2"
  [ -d "$file" ] && is_ram "$file" "$backend" && printf "%s" "$file"
}

get_buffer_file_dirname() {
  backend="$1"
  is_suited_buffer_file_dir "$CPCP_BUFFER_FILE_DIRNAME" "$backend" || \
  is_suited_buffer_file_dir "/run/shm" "$backend" || \
  is_suited_buffer_file_dir "/dev/shm" "$backend" || \
  is_suited_buffer_file_dir "/tmp" "$backend"
}

set_buffer_file() {
  backend="$1"
  buffer_file_basename_stem="cpcp-clipboard-u$(id -u)-g$(id -g)"
  dirname=$(get_buffer_file_dirname "$backend") || return 1
  basename="$buffer_file_basename_stem-$backend"
  file="$dirname/$basename"
  if [ "$backend" = "fifo" ] && [ ! -p "$file" ]; then
    mkfifo -m 600 "$file" 2> /dev/null || return 1
  else
    touch "$file" 2> /dev/null && chmod 600 "$file" 2> /dev/null || return 1
  fi
  buffer_file="$file"
}

set_backend() {
  mode="$1"
  if [ $# -le 1 ]; then
    backend=""
    if [ "$mode" = "auto" ]; then
      printf "%s\n" "$0: no suitable backend could be found" >&2
    else
      printf "%s\n" "$0: backend "$mode" not available" >&2
    fi
    return 2
  fi
  backend="$2"
  if ! {
    ([ "$backend" = "bpcopy" ] && has pbcopy && has pbpaste) || \
    ([ "$backend" = "reattach-to-user-namespace" ] && \
      has reattach-to-user-namespace) || \
    ([ "$backend" = "xsel" ] && has xsel && [ -n "${DISPLAY-}" ]) || \
    ([ "$backend" = "xclip" ] && has xclip && [ -n "${DISPLAY-}" ]) || \
    ([ "$backend" = "nc" ] && has nc && [ "$CPCP_REMOTE_TUNNEL_PORT" ]) || \
    ([ "$backend" = "osc52" ]) || \
    ([ "$backend" = "tmux" ] && has tmux && is_tmux_session) || \
    {([ "$backend" = "fifo" ] || \
      [ "$backend" = "shm" ] || \
      [ "$backend" = "tmp" ]) && set_buffer_file "$backend"; }; } then
    shift 2
    set_backend $mode $@
  fi
}

osc52_encode() {
  data=$(cat "$@")

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

  if is_tmux_session; then
    esc="\033Ptmux;\033$esc\033\\" # " (comment fixes broken syntax highlight)
  fi

  printf "%s" "$esc"
}

local_tty() {
  if is_tmux_session; then
    target_tty=$(tmux list-panes -F "#{pane_active} #{pane_tty}" | \
      sed -n -e 's/^1 /\1/p')
  else
    target_tty=$(is_tty) || target_tty="/dev/tty"
  fi
  printf "%s" "$target_tty"
}

remote_tty() { printf "%s" "$SSH_TTY"; }

tty_guard() {
  target_tty="$1"
  if [ -c "$target_tty" ]; then
    printf "%s" "$target_tty"
  else
    printf "%s\n" "$0: selected non-existent tty \"$target_tty\"" >&2
    printf "%s" "/dev/null"
  fi
}

oneline_args() {
  if [ $# -le 0 ]; then
    oneline=""
  else
    oneline="$1"
    shift 1
    until [ $# -le 0 ]; do
      oneline="$oneline $1"
      shift 1
    done
  fi
  printf "%s" "$oneline"
}

buffer_file=""

dry="false"; verbose="false"

until [ "$#" -le 0 ]; do
  if [ "$1" == "--dry" ]; then
    dry="true"
  elif [ "$1" == "--verbose" ]; then
    verbose="true"
  else
    break
  fi
  shift 1
done

if [ "$#" -le 0 ]; then
  subcommand="$default_subcommand"
else
  subcommand="$1"
  one_of "$subcommand" $subcommands || (print_usage; return 1)
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
  opts=""
  is "$verbose" && opts="--verbose $opts"
  is "$dry" && opts="--dry $opts"

  pipe=$(cat)

  printf "%s" "$pipe" $0 $opts "$subcommand" "local"  "$backend" $@ || return $?
  printf "%s" "$pipe" $0 $opts "$subcommand" "remote" "$backend" $@ || return $?
  return 0
fi

[ "$backend" = "pbpaste" ] && backend="pbcopy"

if [ "$backend" = "auto" ]; then
  if [ "$subcommand" = "copy" ]; then
    if [ "$location" = "local" ]; then
      set_backend "auto" pbcopy reattach-to-user-namespace xsel xclip tmux \
        fifo shm tmp osc52
    elif [ "$location" = "remote" ]; then
      set_backend "auto" nc osc52
    fi
  elif [ "$subcommand" = "paste" ]; then
    if [ "$location" = "local" ]; then
      set_backend "auto" pbcopy reattach-to-user-namespace xsel xclip tmux \
        fifo shm tmp
    elif [ "$location" = "remote" ]; then
      set_backend "auto"
    fi
  fi
else
  set_backend "$backend" "$backend"
fi

[ "$backend" ] || return 2

is "$verbose" && \
  printf "%s\n" "$(oneline_args "$0" "$subcommand" "$location" "$backend" $@)"

command=""

if [ "$subcommand" = "copy" ]; then
  if [ "$location" = "local" ]; then
    case "$backend" in
      "pbcopy") command="pbcopy" ;;
      "reattach-to-user-namespace")
        command="reattach-to-user-namespace pbcopy" ;;
      "xsel") command="xsel -i --clipboard" ;;
      "xclip") command="xclip -i -f -selection primary | \
xclip -i -selection clipboard" ;;
      "nc") command="nc localhost $CPCP_REMOTE_TUNNEL_PORT" ;;
      "osc52")
        command="printf \"\$(osc52_encode)\" > $(tty_guard $(local_tty))" ;;
      "tmux") command="tmux load-buffer -" ;;
      "fifo") command="(data=\$(cat) && \
(printf \"\" > $buffer_file &) > /dev/null && \
cat $buffer_file > /dev/null && \
(printf \"%s\" \"\$data\" > $buffer_file &) > /dev/null)" ;;
      "shm") command="tee > $buffer_file" ;;
      "tmp") command="tee > $buffer_file" ;;
    esac
  elif [ "$location" = "remote" ]; then
    case "$backend" in
      "osc52")
        command="printf \"\$(osc52_encode)\" > $(tty_guard $(remote_tty))" ;;
    esac
  fi
elif [ "$subcommand" = "paste" ]; then
  if [ "$location" = "local" ]; then
    case "$backend" in
      "pbcopy") command="pbpaste" ;;
      "reattach-to-user-namespace")
        command="reattach-to-user-namespace pbpaste" ;;
      "xsel") command="xsel -o --clipboard" ;;
      "xclip") command="xclip -o -selection clipboard" ;;
      "tmux") command="tmux save-buffer -" ;;
      "fifo") command="((printf \"\" > $buffer_file &) > /dev/null && \
data=\$(cat $buffer_file) && \
(printf \"\$data\" > $buffer_file &) > /dev/null && \
printf \"%s\" \"\$data\")" ;;
      "shm") command="cat $buffer_file" ;;
      "tmp") command="cat $buffer_file" ;;
    esac
  elif [ "$location" = "remote" ]; then
    case "$backend" in
      *) ;;
    esac
  fi
fi

if [ "$command" ]; then
  if is "$verbose"; then
    printf "backend command: %s\n" "$command"
  fi
  if ! is "$dry"; then
    if [ "$subcommand" = "copy" ]; then
      data=$(cat "$@")
      printf "%s" "$data" | eval "$command"
    elif [ "$subcommand" = "paste" ]; then
      data=$(eval $command)
      print_data() { is "$verbose" && printf "%s\n" "stdout paste: $data" || \
        printf "%s" "$data"; }
      [ $# -le 0 ] && print_data
      until [ $# -le 0 ]; do
        file="$1"
        if [ "$file" = "-" ]; then
          print_data
        else
          printf "%s" "$data" > "$file"
        fi
        shift 1
      done
    fi
  fi
else
  print_nonexistent_combination "$subcommand" "$location" "$backend"
  return 3
fi

