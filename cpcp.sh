#!/bin/sh

# CPCP – cross platform copy paste

set -e
#set -eu

subcommands="copy paste"
locations="auto local remote both"
backends="auto - pbcopy pbpaste reattach-to-user-namespace xsel xclip nc osc52 \
tmux fifo shm fish tmp"
rand_backends="auto libressl openssl botan urandom random fish"

default_subcommand="copy"
default_location="auto"
default_backend="auto"

cpcp_paste_reliant_backends="tmux fifo shm fish tmp"

compressors="auto false true lz4 gzip xz bzip2"

default_cipher="aes-128-ctr"

indent="|"

fish_universal_clipboard_name="CPCP_CLIPBOARD_FISH"
fish_read_buffer_name="CPCP_CLIPBOARD_FISH_READ_BUFFER"
fish_append_flag_name="CPCP_CLIPBOARD_FISH_APPEND_FLAG"

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
  $0 [opts...] rand n_bytes [$(printf %s "$rand_backends" | tr " " "|")]

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
CPCP_PASTE_REMOTE_PRIORITY_LIST: same as above for other subcommands and \
locations.
  * CPCP_COPY_PRE_PIPE, CPCP_COPY_POST_PIPE can be set to apply additional \
pipelines to the data before and after compression, encryption and base64 \
coding occurs.
  * CPCP_PASTE_PRE_PIPE, CPCP_PASTE_POST_PIPE: same as above for paste \
subcommand.
  * CPCP_COMPRESSOR_PRIORITY_LIST can be set to override the default set and \
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
  * CPCP_BASE64_COMMAND can be used to override the choice of base64 codec.
  * CPCP_RAND_PRIORITY_LIST can be set to override the default set and \
order of random number generators to try for $0 rand."

  printf "%s\n" "$msg"
}

is() ( [ "$1" = "true" ]; )

has() ( [ "$1" ] && type "$1" 1> /dev/null 2> /dev/null; )

one_of() (
  word="$1"
  shift 1
  [ $# -le 0 ] && return 1
  [ "$word" = "$1" ] && return 0
  shift 1
  one_of $word $@
)

is_unsigned ()
{
    case "$1" in
        (*[!0123456789]*) return 1 ;;
        ('')              return 1 ;;
        (*)               return 0 ;;
    esac
}

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
  cmd="$1"
  mode="$2"
  if [ $# -le 2 ]; then
    backend=""
    if [ "$mode" = "auto" ]; then
      is "$verbose" && v=" (priority list: $backend_priority_list)" || v=""
      printf "%s\n" "$0: no suitable backend could be found$v" >&2
    else
      printf "%s\n" "$0: backend "$mode" not available" >&2
    fi
    return 1
  fi
  backend="$3"
  if { [ "$cmd" != "rand" ] && ! {
    ([ "$backend" = "pbcopy" ] && has pbcopy && has pbpaste) || \
    ([ "$backend" = "reattach-to-user-namespace" ] && \
      has reattach-to-user-namespace) || \
    ([ "$backend" = "xsel" ] && has xsel && [ -n "${DISPLAY-}" ]) || \
    ([ "$backend" = "xclip" ] && has xclip && [ -n "${DISPLAY-}" ]) || \
    ([ "$backend" = "nc" ] && has nc && [ "$CPCP_REMOTE_TUNNEL_PORT" ]) || \
    ([ "$backend" = "osc52" ]) || \
    ([ "$backend" = "tmux" ] && has tmux && is_tmux_session) || \
    {(one_of "$backend" "fifo" "shm" "tmp") && \
      set_buffer_file "$backend"; } || \
    ([ "$backend" = "fish" ] && has fish) || \
    ([ "$backend" = "-" ]); } } || \
    { [ "$cmd" = "rand" ] && ! {
    ([ "$backend" = "libressl" ] && has libressl) || \
    ([ "$backend" = "openssl" ] && has openssl) || \
    ([ "$backend" = "botan" ] && has botan && botan has_command rng) || \
    ([ "$backend" = "urandom" ] && test -c /dev/urandom) || \
    ([ "$backend" = "random" ] && test -c /dev/random) || \
    ([ "$backend" = "fish" ] && has fish && fish -c "type -q random" && \
      fish -c "type -q math" && fish -c "type -q string" && \
      get_base64_command 1> /dev/null)
    } } then
    shift 3
    set_backend "$cmd" "$mode" $@
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
  (printf "%s\n" "$0: no valid encryption command could be found" >&2;
    return 1)
  # TODO: Add `botan` as an encryption command
)

get_base64_command() (
  decode="false"
  [ $# = 1 ] && one_of "$1" "paste" "--decode" "-d" && decode="true"
  is "$decode" && d_flag=" -d" || d_flag=""
  is "$decode" && botan_cmd="base64_dec" || botan_cmd="base64_enc"
  (has "$CPCP_BASE64_COMMAND" && \
    printf "$CPCP_BASE64_COMMAND$d_flag") || \
  (has base64   && printf "base64$d_flag") || \
  (has libressl && printf "libressl base64$d_flag") || \
  (has openssl  && printf "openssl base64$d_flag") || \
  (has "$CPCP_ENCRYPTION_COMMAND" && \
    printf "$CPCP_ENCRYPTION_COMMAND base64$d_flag") || \
  (has botan && botan has_command "$botan_cmd" && \
    printf "botan $botan_cmd -") || \
  (printf "%s\n" "$0: no valid base64 codec could be found" >&2;
    return 1)
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
  one_of "$subcommand" $subcommands || [ "$subcommand" = "rand" ] || \
    (print_usage; exit 1)
  shift 1
fi

if [ "$#" -le 0 ]; then
  location="$default_location"
  [ "$subcommand" = "rand" ] && \
    (printf "%s\n" "$0: missing argument n_bytes" >&2; exit 9)
else
  if [ "$subcommand" = "rand" ]; then
    location=""
    n_bytes="$1"
    is_unsigned "$n_bytes" || (printf "%s\n" \
      "$0: n_bytes \"$n_bytes\" is not an unsigned integer" >&2; exit 8)
  else
    location="$1"
    n_bytes=""
    one_of "$location" $locations || (print_usage; exit 1)
  fi
  shift 1
fi

if [ "$#" -le 0 ]; then
  backend="$default_backend"
else
  backend="$1"
  if [ "$subcommand" = "rand" ]; then
    one_of "$backend" $rand_backends || (print_usage; exit 1)
  else
    one_of "$backend" $backends || (print_usage; exit 1)
  fi
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

  # `x` is a workaround, see twoards the end of the script where it's also done.
  in=$(cat; printf "x"); in="${data%x}"

  printf "%s" "$in" | $0 $opts "$subcommand" "local"  "$backend" $@ || exit $?
  printf "%s" "$in" | $0 $opts "$subcommand" "remote" "$backend" $@ || exit $?
  exit 0
fi

[ "$backend" = "pbpaste" ] && backend="pbcopy"

backend_priority_list=""
backend_priority_list_printable="false"
if [ "$backend" = "auto" ]; then
  backend_priority_list_printable="true"
  if [ "$subcommand" = "copy" ]; then
    if [ "$location" = "local" ]; then
      backend_priority_list="$CPCP_COPY_LOCAL_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list="pbcopy \
        reattach-to-user-namespace xsel xclip tmux fifo shm fish tmp osc52"
    elif [ "$location" = "remote" ]; then
      backend_priority_list="$CPCP_COPY_REMOTE_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list="nc osc52"
    fi
  elif [ "$subcommand" = "paste" ]; then
    if [ "$location" = "local" ]; then
      backend_priority_list="$CPCP_PASTE_LOCAL_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list="\
        pbcopy reattach-to-user-namespace xsel xclip tmux fifo shm fish tmp"
    elif [ "$location" = "remote" ]; then
      backend_priority_list="$CPCP_PASTE_REMOTE_PRIORITY_LIST"
      [ "$backend_priority_list" ] || backend_priority_list=""
    fi
  elif [ "$subcommand" = "rand" ]; then
    backend_priority_list="$CPCP_RAND_PRIORITY_LIST"
    [ "$backend_priority_list" ] || backend_priority_list="libressl openssl \
      botan urandom random fish"
  fi
  backend_priority_list=$(oneline_args $backend_priority_list)
  set_backend "$subcommand" "auto" $backend_priority_list || exit 2
else
  set_backend "$subcommand" "$backend" "$backend" || exit 2
fi

[ "$backend" ] || exit 2

if one_of "$backend" $cpcp_paste_reliant_backends && \
  [ "$subcommand" != "rand" ]; then
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
      exit 7
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

# Always enable base64 for fish backend
# Note: Fish seems to be able to recognize if binary data is stored in variables
# sometimes, and it may be possible to get binary data in and out of its
# variables unchanged without issues. But at the moment, I'm not sure how to do
# this properly. Thus, let's just use base64 as a safer workaround for now.
# TODO: Work this out (don't depend on base64 for fish backend)
[ "$backend" = "fish" ] && [ "$subcommand" != "rand" ] && base64="true"

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
  "$location$n_bytes" "$backend" $@)"
is "$verbose" && is "$backend_priority_list_printable" && printf \
  "$indent %s\n" "using backend priority list: $backend_priority_list"
is "$verbose" && [ ! "$compress" = "false" ] && \
  is "$compressor_priority_list_printable" && printf \
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
      "fish") command="fish -c \"\
while read --null part; \
if not set --query $fish_append_flag_name; \
set $fish_read_buffer_name \\\$part; \
set $fish_append_flag_name; \
else; \
  set --append $fish_read_buffer_name \\\$part; \
end; \
end; \
set --erase $fish_append_flag_name; \
set --universal --export $fish_universal_clipboard_name \
\\\$$fish_read_buffer_name\
\"" ;;
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
      "fish") command="fish -c \"\
if set --query $fish_universal_clipboard_name[1]; \
printf \\\"%s\\\" \\\$$fish_universal_clipboard_name[1]; \
end; \
if set --query $fish_universal_clipboard_name[2]; \
for part in \\\$$fish_universal_clipboard_name[2..-1]; \
printf \\\"\0%s\\\" \\\$part; \
end; \
end\
\"" ;;
      "tmp") command="cat $buffer_file" ;;
      "-") command="cat"
    esac
  elif [ "$location" = "remote" ]; then
    case "$backend" in
      *) ;;
    esac
  fi
elif [ "$subcommand" = "rand" ]; then
  if is "$base64" && [ "$compress" = "false" ] && [ "$encrypt" = "false" ]; then
    base64_here="true"
  else
    base64_here="false"
  fi
  case "$backend" in
    # Note: usages of `dd` here should always use `bs=1`, because they can be
    # unreliable otherwise. This is especially important for reading from
    # `/dev/random`, but definitely not limited to that case!
    # Also see `https://unix.stackexchange.com/questions/278443/whats-the-posix-
    # way-to-read-an-exact-number-of-bytes-from-a-file`.
    "libressl"|"openssl")
      command="$backend rand"
      is "$base64_here" && command="$command -base64"
      command="$command $n_bytes" ;;
    "botan")
      command="botan rng"
      is "$base64_here" && command="$command --format=base64"
      command="$command $n_bytes" ;;
    "urandom"|"random")
      command="dd if=/dev/$backend bs=1 count=$n_bytes 2> /dev/null"
      if is "$base64_here"; then
        base64_command=$(get_base64_command "$subcommand") || exit 6
        command="$command | $base64_command"
      fi ;;
    "fish")
      base64_command=$(get_base64_command --decode) || exit 6
      command="fish -c \"\
for i in (seq (math --scale=0 \\\"ceil($n_bytes / 3) x 4\\\")); \
random choice \
a b c d e f g h i j k l m n o p q r s t u v w x y z \
A B C D E F G H I J K L M N O P Q R S T U V W X Y Z \
0 1 2 3 4 5 6 7 8 9 \
\\\"/\\\" \\\"+\\\"; \
end | \
string join \\\"\\\"\" | \
$base64_command | \
dd bs=1 count=$n_bytes 2> /dev/null"
      if is "$base64_here"; then
        base64_command=$(get_base64_command "$subcommand") || exit 6
        command="$command | $base64_command"
      fi ;;
  esac
fi

data_pipe=""

if [ "$subcommand" = "copy" ] && [ "$CPCP_COPY_PRE_PIPE" ]; then
  data_pipe="$CPCP_COPY_PRE_PIPE | $data_pipe"
elif [ "$subcommand" = "paste" ] && [ "$CPCP_PASTE_PRE_PIPE" ]; then
  data_pipe=" | $CPCP_PASTE_PRE_PIPE$data_pipe"
fi

if [ ! "$compress" = "false" ]; then
  if one_of "$subcommand" "copy" "rand"; then
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
    exit 7
  fi
fi

if is "$encrypt"; then
  encryption_command=$(get_encryption_command) || exit 4
  [ "$CPCP_ENCRYPTION_KEY" ] || (printf "%s\n" "$0: encryption requested but \
CPCP_ENCRYPTION_KEY is empty" >&2 && exit 5)
  if [ "$CPCP_ENCRYPTION_CIPHER" ]; then
    cipher="$CPCP_ENCRYPTION_CIPHER"
  else
    cipher="$default_cipher"
  fi
  if is "$base64"; then
    base64_option=" -base64"
  else
    base64_option=""
  fi
  if one_of "$subcommand" "copy" "rand"; then
    data_pipe="$data_pipe$encryption_command $cipher -e -salt -pass \
env:CPCP_ENCRYPTION_KEY$base64_option | "
  elif [ "$subcommand" = "paste" ]; then
    data_pipe=" | $encryption_command $cipher -d -pass \
env:CPCP_ENCRYPTION_KEY$base64_option$data_pipe"
  fi
elif is "$base64" && \
    ([ "$subcommand" != "rand" ] || [ "$compress" != "false" ]); then
  base64_command=$(get_base64_command "$subcommand") || exit 6
  if one_of "$subcommand" "copy" "rand"; then
    data_pipe="$data_pipe$base64_command | "
  elif [ "$subcommand" = "paste" ]; then
    data_pipe=" | $base64_command$data_pipe"
  fi
fi

if [ "$subcommand" = "copy" ] && [ "$CPCP_COPY_POST_PIPE" ]; then
  data_pipe="$data_pipe$CPCP_COPY_POST_PIPE | "
elif [ "$subcommand" = "paste" ] && [ "$CPCP_PASTE_POST_PIPE" ]; then
  data_pipe="$data_pipe | $CPCP_PASTE_POST_PIPE"
fi

if [ "$command" ]; then
  [ "$data_pipe" ] && [ "$subcommand" = "rand" ] && \
    data_pipe=$(printf "%s" " | $data_pipe" | sed 's/...$//')
  if is "$verbose"; then
    printf "$indent %s\n" "to backend command: $command"
    [ "$data_pipe" ] && printf "$indent %s\n" "via pipe command: $data_pipe"
  fi
  if ! is "$dry"; then
    if [ "$subcommand" = "copy" ]; then
      # The thing with the `x` below is a workaround to make sure newlines are
      # not ignored.
      data=$(cat "$@"; printf "x"); data="${data%x}"
      is "$verbose" && printf "$indent %s\n" "fed input: $data"
      [ "$data_pipe" ] && command="$data_pipe$command"
      printf "%s" "$data" | (eval "$command")
    elif one_of "$subcommand" "paste" "rand"; then
      [ "$data_pipe" ] && command="$command$data_pipe"
      # Note: if input is empty, a data pipe that tries to decrypt or decompress
      # may issue an error. I will leave it this way for now.
      # Here's the `x` workaround once more
      data=$(eval $command; printf "x"); data="${data%x}"
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
  exit 3
fi

