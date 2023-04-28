#!/bin/sh

# CPCP – cross platform copy paste

set -e
#set -eu

subcommands="copy paste"
locations="auto local remote both"
backends="auto - pbcopy pbpaste reattach-to-user-namespace xsel xclip nc osc52 \
tmux fifo shm tmp"

default_subcommand="copy"
default_location="auto"
default_backend="auto"

cpcp_paste_reliant_backends="tmux fifo shm tmp"

compressors="auto false true lz4 gzip xz bzip2"

default_cipher="aes-128-ctr"

indent="|"

print_usage() {
  msg="Usage:
  $0 [--dry] [--verbose] \\
    [--compress=($(printf %s "$compressors" | tr " " "|"))] \\
    [--encrypt=(auto|false|true)] \\
    [--base64=(false|true|auto)] \\
    [$(printf %s "$subcommands" | tr " " "|")] \\
    [$(printf %s "$locations" | tr " " "|")] \\
    [$(printf %s "$backends" | tr " " "|")] \\
    [files...]

Notes:
  The default subcommand, location, and backend are $default_subcommand, \
$default_location, and $default_backend, respectively.

  The default for files is -, i.e. stdin/stdout.

  The default values for omitted options --compress, --encrypt, and --base64 \
are auto, auto, and false.
  When one of these options is given without a value, it defaults to true.

Environment variables:
  * CPCP_REMOTE_TUNNEL_PORT has to be set for the nc backend to be available.
  * CPCP_BUFFER_FILE_DIRNAME can be set to use a custom directory for the \
fifo, shm (if filesystem is in-memory), and tmp backends.
  * CPCP_COPY_LOCAL_PRIORITY_LIST can be set to override the default set and \
order of backends to try for $0 copy local auto.
  * CPCP_COPY_REMOTE_PRIORITY_LIST, CPCP_PASTE_LOCAL_PRIORITY_LIST, \
CPCP_PASTE_REMOTE_RPIORITY_LIST: same as above for other subcommands and \
locations.
  * CPCP_COPY_PRE_PIPE, CPCP_COPY_POST_PIPE: can be set to apply additional \
pipelines to the data before and after compression, encryption and base64 \
coding occurs.
  * CPCP_PASTE_PRE_PIPE, CPCP_PASTE_POST_PIPE: same as above for paste \
subcommand.
  * CPCP_COMPRESSOR_PRIORITY_LIST: can be set to override the default set and \
order of compressors to try when --compress is auto or true.
  * CPCP_COMPRESSION_PIPE, CPCP_DECOMPRESSION_PIPE: for detailed control of \
compression pipelines.
  * CPCP_ENCRYPTION_KEY will be used as encryption password. This is NOT \
secure by any means but may provide some elementary protection from e.g. \
passwords being stored in buffer files as cleartext.
  * CPCP_ENCRYPTION_COMMAND can be used to override the choice of cryptography \
library.
  * CPCP_ENCRYPTION_CIPHER can be used to choose an encryption cipher (default \
is $default_cipher).
  * CPCP_BASE64_COMMAND can be used to override the choice of base64 codec."

  printf "%s\n" "$msg"
}

is() ( [ "$1" = "true" ]; )

has() ( [ "$1" ] && type "$1" 1> /dev/null; )

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
      is "$verbose" && v=" (priority list: $backend_priority_list)" || v=""
      printf "%s\n" "$0: no suitable backend could be found$v" >&2
    else
      printf "%s\n" "$0: backend "$mode" not available" >&2
    fi
    return 1
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
    {(one_of "$backend" "fifo" "shm" "tmp") && \
      set_buffer_file "$backend"; } || \
    ([ "$backend" = "-" ]); } then
    shift 2
    set_backend $mode $@
  fi
}

set_compressor() {
  mode="$1"
  if [ $# -le 1 ]; then
    compressor=""; return 1
  fi
  compressor="$2"
  if ! {
    ([ "$compressor" = "true" ] && \
      [ "$CPCP_COMPRESSION_PIPE" ] && [ "$CPCP_DECOMPRESSION_PIPE" ]) || \
    ([ "$compressor" = "lz4" ] && has lz4) || \
    ([ "$compressor" = "xz" ] && has xz) || \
    ([ "$compressor" = "gzip" ] && has gzip) || \
    ([ "$compressor" = "bzip2" ] && has bzip2); } then
    shift 2
    set_compressor $mode $@
  fi
}

osc52_encode() (
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
)

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

oneline_args() (
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
)

get_encryption_command() (
  (has "$CPCP_ENCRYPTION_COMMAND" && \
    printf "$CPCP_ENCRYPTION_COMMAND") || \
  (has libressl && printf "libressl") || \
  (has openssl  && printf "openssl") || \
  printf "%s\n" "$0: no valid encryption command cound be found" >&2
)

get_base64_command() (
  (has "$CPCP_BASE64_COMMAND" && \
    printf "$CPCP_BASE64_COMMAND") || \
  (has base64   && printf "base64") || \
  (has libressl && printf "libressl base64") || \
  (has openssl  && printf "openssl base64") || \
  (has "$CPCP_ENCRYPTION_COMMAND" && \
    printf "$CPCP_ENCRYPTION_COMMAND base64") || \
  printf "%s\n" "$0: no valid base64 codec could be found" >&2
)

buffer_file=""

dry="false"; verbose="false"; compress="auto"; encrypt="auto"; base64="false"

until [ "$#" -le 0 ]; do
  case "$1" in
    "--dry") dry="true" ;;
    "--verbose") verbose="true" ;;
    "--compress=auto") compress="auto" ;;
    "--compress=false") compress="false" ;;
    "--compress=true") compress="true" ;;
    "--compress="*) compress=$(printf "%s" "$1" | sed -e 's/^compress=//') ;;
    "--compress") compress="true" ;;
    "--encrypt=auto") encrypt="auto" ;;
    "--encrypt=false") encrypt="false" ;;
    "--encrypt=true") encrypt="true" ;;
    "--encrypt") encrypt="true" ;;
    "--base64=auto") base64="auto" ;;
    "--base64=false") base64="false" ;;
    "--base64=true") base64="true" ;;
    "--base64") base64="true" ;;
    *) break ;;
  esac
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
  opts="--compress=$compress --encrypt=$encrypt --base64=$base64"
  is "$verbose" && opts="--verbose $opts"
  is "$dry" && opts="--dry $opts"

  in=$(cat)

  printf "%s" "$in" | $0 $opts "$subcommand" "local"  "$backend" $@ || return $?
  printf "%s" "$in" | $0 $opts "$subcommand" "remote" "$backend" $@ || return $?
  return 0
fi

[ "$backend" = "pbpaste" ] && backend="pbcopy"

backend_priority_list=""
backend_priority_list_printable="false"
if [ "$backend" = "auto" ]; then
  backend_priority_list_printable="true"
  if [ "$subcommand" = "copy" ]; then
    if [ "$location" = "local" ]; then
      backend_priority_list="$CPCP_COPY_LOCAL_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list="\
        pbcopy reattach-to-user-namespace xsel xclip tmux fifo shm tmp osc52"
    elif [ "$location" = "remote" ]; then
      backend_priority_list="$CPCP_COPY_REMOTE_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list="nc osc52"
    fi
  elif [ "$subcommand" = "paste" ]; then
    if [ "$location" = "local" ]; then
      backend_priority_list="$CPCP_PASTE_LOCAL_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list="\
        pbcopy reattach-to-user-namespace xsel xclip tmux fifo shm tmp"
    elif [ "$location" = "remote" ]; then
      backend_priority_list="$CPCP_PASTE_REMOTE_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list=""
    fi
  fi
  backend_priority_list=$(oneline_args $backend_priority_list)
  set_backend "auto" $backend_priority_list
else
  set_backend "$backend" "$backend"
fi

[ "$backend" ] || return 2

if one_of "$backend" $cpcp_paste_reliant_backends; then
  cpcp_paste_reliant_backend="true"
else
  cpcp_paste_reliant_backend="false"
fi

if [ ! "$compress" = "false" ]; then
  compressor_priority_list=""
  compressor_priority_list_printable="false"
  if one_of "$compress" "auto" "true"; then
    compressor_priority_list_printable="true"
    compressor_priority_list="$CPCP_COMPRESSOR_PRIORITY_LIST"
    [ "$compressor_priority_list" ] || compressor_priority_list="\
      true lz4 gzip xz bzip2"
    compressor_priority_list=$(oneline_args $compressor_priority_list)
    set_compressor "auto" $compressor_priority_list
  else
    set_compressor "$compress" "$compress"
  fi

  if [ "$compress" = "auto" ]; then
    if [ "$compressor" ] && is "$cpcp_paste_reliant_backend"; then
      compress="$compressor"
    else
      compress="false"
    fi
  else
    if [ ! "$compressor" ]; then
      if is "$compress"; then
        is "$verbose" && v=" (priority list: $compressor_priority_list)" || v=""
        printf "%s\n" "$0: no suitable compressor could be found$v" >&2
      else
        printf "%s\n" "$0: compressor "$compress" not available" >&2
      fi
      return 7
    fi
    compress="$compressor"
  fi
fi

if [ "$encrypt" = "auto" ]; then
  if [ "$CPCP_ENCRYPTION_KEY" ] && \
    (get_encryption_command 1> /dev/null) && \
    (is "$cpcp_paste_reliant_backend"); then
    encrypt="true"
  else
    encrypt="false"
  fi
fi

if [ "$base64" = "auto" ]; then
  if (get_base64_command 1> /dev/null) && \
    (is "$cpcp_paste_reliant_backend" || [ "$backend" = "-" ]); then
    base64="true"
  else
    base64="false"
  fi
fi

is "$verbose" && printf "resolved command: %s\n" "$(oneline_args "$0" \
  --compress="$compress" --encrypt="$encrypt" --base64="$base64" "$subcommand" \
  "$location" "$backend" $@)"
is "$verbose" && is "$backend_priority_list_printable" && printf \
  "$indent %s\n" "using backend priority list: $backend_priority_list"
is "$verbose" && is "$compressor_priority_list_printable" && printf \
  "$indent %s\n" "using compressor priority list: $compressor_priority_list"

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
      "-") command="cat"
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
      "-") command="cat"
    esac
  elif [ "$location" = "remote" ]; then
    case "$backend" in
      *) ;;
    esac
  fi
fi

data_pipe=""

if [ "$subcommand" = "copy" ] && [ "$CPCP_COPY_PRE_PIPE" ]; then
  data_pipe="$CPCP_COPY_PRE_PIPE | $data_pipe"
elif [ "$subcommand" = "paste" ] && [ "$CPCP_PASTE_PRE_PIPE" ]; then
  data_pipe=" | $CPCP_PASTE_PRE_PIPE$data_pipe"
fi

if [ ! "$compress" = "false" ]; then
  if [ "$subcommand" = "copy" ]; then
    case "$compress" in
      "true") compression_command="$CPCP_COMPRESSION_PIPE" ;;
      "lz4") compression_command="lz4 -c -z" ;;
      "gzip") compression_command="gzip -c" ;;
      "xz") compression_command="xz -c -z" ;;
      "bzip2") compression_command="bzip2 -c -z" ;;
    esac
    data_pipe="$data_pipe$compression_command | "
  elif [ "$subcommand" = "paste" ]; then
    case "$compress" in
      "true") compression_command="$CPCP_DECOMPRESSION_PIPE" ;;
      "lz4") compression_command="lz4 -c -d" ;;
      "gzip") compression_command="gzip -c -d" ;;
      "xz") compression_command="xz -c -d" ;;
      "bzip2") compression_command="bzip2 -c -d" ;;
    esac
    data_pipe=" | $compression_command$data_pipe"
  fi
  if [ ! "$compression_command" ]; then
    printf "%s\n" "$0: compressor "$compress" not available" >&2
    return 7
  fi
fi

if is "$encrypt"; then
  encryption_command=$(get_encryption_command) || return 4
  [ "$CPCP_ENCRYPTION_KEY" ] || (printf "%s\n" "$0: encryption requested but \
CPCP_ENCRYPTION_KEY is empty" >&2 && return 5)
  if [ "$CPCP_ENCRYPTION_CIPHER" ]; then
    cipher="$CPCP_ENCRYPTION_CIPHER"
  else
    cipher="$default_cipher"
  fi
  if [ "$subcommand" = "copy" ]; then
    data_pipe="$data_pipe$encryption_command $cipher -e -salt -pass \
env:CPCP_ENCRYPTION_KEY | "
  elif [ "$subcommand" = "paste" ]; then
    data_pipe=" | $encryption_command $cipher -d -pass \
env:CPCP_ENCRYPTION_KEY$data_pipe"
  fi
  is "$base64" && data_pipe="$data_pipe -base64"
elif is "$base64"; then
  base64_command=$(get_base64_command) || return 6
  if [ "$subcommand" = "copy" ]; then
    data_pipe="$data_pipe$base64_command | "
  elif [ "$subcommand" = "paste" ]; then
    data_pipe=" | $base64_command -d$data_pipe"
  fi
fi

if [ "$subcommand" = "copy" ] && [ "$CPCP_COPY_POST_PIPE" ]; then
  data_pipe="$data_pipe$CPCP_COPY_POST_PIPE | "
elif [ "$subcommand" = "paste" ] && [ "$CPCP_PASTE_POST_PIPE" ]; then
  data_pipe="$data_pipe | $CPCP_PASTE_POST_PIPE"
fi

if [ "$command" ]; then
  if is "$verbose"; then
    printf "$indent %s\n" "to backend command: $command"
    [ "$data_pipe" ] && printf "$indent %s\n" "via pipe command: $data_pipe"
  fi
  if ! is "$dry"; then
    if [ "$subcommand" = "copy" ]; then
      data=$(cat "$@")
      is "$verbose" && printf "$indent %s\n" "fed input: $data"
      [ "$data_pipe" ] && command="$data_pipe$command"
      printf "%s" "$data" | (eval "$command")
    elif [ "$subcommand" = "paste" ]; then
      [ "$data_pipe" ] && command="$command$data_pipe"
      data=$(eval $command)
      print_data() { is "$verbose" && printf "$indent %s\n" \
        "resulting in: $data" || printf "%s" "$data"; }
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
  printf "%s\n" "$0: combination of arguments $subcommand $location $backend \
not available" >&2
  return 3
fi

