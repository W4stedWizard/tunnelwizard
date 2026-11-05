#!/usr/bin/env bash
# Bash profile management for the host-wide Alias pane. Never source .bashrc.
ALIAS_BLOCK_BEGIN='# >>> TunnelWizard Bash aliases >>>'
ALIAS_BLOCK_FINISH='# <<< TunnelWizard Bash aliases <<<'

alias_profile_read() {
    local path=${HOME:-}/.bashrc line plain index=-1 name raw decoded encoded
    local escape="'\\''" found=0 ended=0
    local -A seen=()
    ALIAS_ERROR=""
    ALIAS_NAMES=()
    ALIAS_COMMANDS=()
    BASHRC_LINES=()
    ALIAS_BLOCK_START=-1
    ALIAS_BLOCK_END=-1
    BASHRC_FINAL_NEWLINE=1
    BASHRC_EOL=$'\n'
    BASHRC_CHECKSUM=""
    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        ALIAS_ERROR='HOME is unavailable; set HOME before managing ~/.bashrc.'
        return 1
    fi
    if [[ -L "$path" ]]; then
        ALIAS_ERROR='~/.bashrc is a symlink; edit its target manually (no changes made).'
        return 1
    fi
    if [[ -e "$path" && ( ! -f "$path" || ! -r "$path" ) ]]; then
        ALIAS_ERROR='~/.bashrc is not a readable regular file; fix permissions first.'
        return 1
    fi
    if [[ -e "$path" ]]; then
        if ! BASHRC_CHECKSUM=$(cksum < "$path" 2>/dev/null); then
            ALIAS_ERROR='Cannot read ~/.bashrc; check its permissions.'
            return 1
        fi
        while true; do
            if IFS= read -r line; then
                BASHRC_LINES+=("$line")
                BASHRC_FINAL_NEWLINE=1
            elif [[ -n "$line" ]]; then
                BASHRC_LINES+=("$line")
                BASHRC_FINAL_NEWLINE=0
                break
            else
                break
            fi
        done < "$path"
        if [[ "$BASHRC_CHECKSUM" != "$(cksum < "$path" 2>/dev/null)" ]]; then
            ALIAS_ERROR='~/.bashrc changed while reading; reopen Aliases and retry.'
            return 1
        fi
    fi
    for index in "${!BASHRC_LINES[@]}"; do
        line=${BASHRC_LINES[$index]}
        # Prefer CRLF for the managed block if the profile already uses it
        # anywhere, including mixed-ending files edited by hand.
        if [[ "$line" == *$'\r' ]]; then BASHRC_EOL=$'\r\n'; fi
        plain=${line%$'\r'}
        if [[ "$plain" == "$ALIAS_BLOCK_BEGIN" ]]; then
            if ((found)); then
                ALIAS_ERROR='Duplicate or nested TunnelWizard block in ~/.bashrc; repair markers manually.'
                return 1
            fi
            found=1
            ALIAS_BLOCK_START=$index
        elif [[ "$plain" == "$ALIAS_BLOCK_FINISH" ]]; then
            if ((!found || ended)); then
                ALIAS_ERROR='Unmatched TunnelWizard block marker in ~/.bashrc; repair it manually.'
                return 1
            fi
            ended=1
            ALIAS_BLOCK_END=$index
        elif [[ "$plain" =~ ^#[[:space:]]*(>>>|<<<).*TunnelWizard[[:space:]]+Bash[[:space:]]+aliases ]]; then
            ALIAS_ERROR='Malformed TunnelWizard marker in ~/.bashrc; repair it manually.'
            return 1
        elif ((found && !ended)); then
            if [[ ! "$plain" =~ ^alias[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)=\'(.*)\'$ ]]; then
                ALIAS_ERROR='Invalid alias in TunnelWizard block; repair ~/.bashrc manually.'
                return 1
            fi
            name=${BASH_REMATCH[1]}
            raw=${BASH_REMATCH[2]}
            decoded=${raw//"$escape"/\'}
            encoded=${decoded//\'/"$escape"}
            if [[ -n "${seen[$name]:-}" || "$plain" != "alias $name='$encoded'" ]]; then
                ALIAS_ERROR='Duplicate or invalid alias in TunnelWizard block; repair ~/.bashrc manually.'
                return 1
            fi
            seen[$name]=1
            ALIAS_NAMES+=("$name")
            ALIAS_COMMANDS+=("$decoded")
        fi
    done
    if ((found && !ended)); then
        ALIAS_ERROR='Unclosed TunnelWizard block in ~/.bashrc; add its end marker manually.'
        return 1
    fi
}

# Atomically replace only the managed block, preserving unrelated lines and
# their line endings. A changed profile is refused rather than overwritten.
alias_profile_write() {
    local path=${HOME:-}/.bashrc temp snapshot i name encoded
    local escape="'\\''" last=$(( ${#BASHRC_LINES[@]} - 1 ))
    local count=${#ALIAS_NAMES[@]}
    ALIAS_ERROR=""
    if [[ -L "$path" || ( -e "$path" && ( ! -f "$path" || ! -r "$path" ) ) ]]; then
        ALIAS_ERROR='~/.bashrc changed or is inaccessible; reopen Aliases before editing.'
        return 1
    fi
    if ! temp=$(mktemp "$path.tunnelwizard.XXXXXX" 2>/dev/null); then
        ALIAS_ERROR='Cannot create a temporary file beside ~/.bashrc; check home permissions.'
        return 1
    fi
    if ! snapshot=$(mktemp "$path.tunnelwizard.XXXXXX" 2>/dev/null); then
        rm -f -- "$temp"
        ALIAS_ERROR='Cannot create a profile snapshot; check home permissions.'
        return 1
    fi
    if [[ -e "$path" ]] &&
       { ! cp -p -- "$path" "$snapshot" 2>/dev/null ||
         ! cp -p -- "$snapshot" "$temp" 2>/dev/null; }; then
        rm -f -- "$temp" "$snapshot"
        ALIAS_ERROR='Cannot copy ~/.bashrc safely; check file permissions and free space.'
        return 1
    fi
    if [[ -e "$path" ]]; then
        if [[ -z "$BASHRC_CHECKSUM" ||
              "$(cksum < "$snapshot" 2>/dev/null)" != "$BASHRC_CHECKSUM" ]]; then
            rm -f -- "$temp" "$snapshot"
            ALIAS_ERROR='~/.bashrc changed since opening Aliases; reopen and retry.'
            return 1
        fi
    elif [[ -n "$BASHRC_CHECKSUM" ]]; then
        rm -f -- "$temp" "$snapshot"
        ALIAS_ERROR='~/.bashrc disappeared since opening Aliases; reopen and retry.'
        return 1
    fi
    # Bash read discards NUL bytes. Refuse rather than silently dropping any
    # bytes that cannot be represented by the parsed line model.
    if ! {
        for i in "${!BASHRC_LINES[@]}"; do
            printf '%s' "${BASHRC_LINES[$i]}"
            if ((i < last || BASHRC_FINAL_NEWLINE)); then printf '\n'; fi
        done
    } > "$temp" || ! cmp -s -- "$temp" "$snapshot"; then
        rm -f -- "$temp" "$snapshot"
        ALIAS_ERROR='Cannot safely preserve ~/.bashrc bytes; remove binary data or check free space.'
        return 1
    fi
    if ! {
        for i in "${!BASHRC_LINES[@]}"; do
            if ((i == ALIAS_BLOCK_START)); then
                if ((count)); then
                    printf '%s%s' "$ALIAS_BLOCK_BEGIN" "$BASHRC_EOL"
                    for name in "${!ALIAS_NAMES[@]}"; do
                        encoded=${ALIAS_COMMANDS[$name]//\'/"$escape"}
                        printf "alias %s='%s'%s" "${ALIAS_NAMES[$name]}" "$encoded" "$BASHRC_EOL"
                    done
                    printf '%s' "$ALIAS_BLOCK_FINISH"
                    if ((ALIAS_BLOCK_END < last || BASHRC_FINAL_NEWLINE)); then
                        printf '%s' "$BASHRC_EOL"
                    fi
                fi
            fi
            if ((i >= ALIAS_BLOCK_START && ALIAS_BLOCK_START >= 0 && i <= ALIAS_BLOCK_END)); then
                continue
            fi
            printf '%s' "${BASHRC_LINES[$i]}"
            if ((i < last || BASHRC_FINAL_NEWLINE)); then printf '\n'; fi
        done
        if ((ALIAS_BLOCK_START < 0 && count)); then
            if ((last >= 0 && !BASHRC_FINAL_NEWLINE)); then printf '\n'; fi
            printf '%s%s' "$ALIAS_BLOCK_BEGIN" "$BASHRC_EOL"
            for name in "${!ALIAS_NAMES[@]}"; do
                encoded=${ALIAS_COMMANDS[$name]//\'/"$escape"}
                printf "alias %s='%s'%s" "${ALIAS_NAMES[$name]}" "$encoded" "$BASHRC_EOL"
            done
            printf '%s%s' "$ALIAS_BLOCK_FINISH" "$BASHRC_EOL"
        fi
    } > "$temp"; then
        rm -f -- "$temp" "$snapshot"
        ALIAS_ERROR='Could not write the temporary Bash profile; ~/.bashrc was not changed.'
        return 1
    fi
    if [[ -e "$path" ]]; then
        if [[ -z "$BASHRC_CHECKSUM" ]] || ! cmp -s -- "$path" "$snapshot"; then
            rm -f -- "$temp" "$snapshot"
            ALIAS_ERROR='~/.bashrc changed during editing; reopen Aliases and retry.'
            return 1
        fi
    elif [[ -n "$BASHRC_CHECKSUM" || -L "$path" ]]; then
        rm -f -- "$temp" "$snapshot"
        ALIAS_ERROR='~/.bashrc changed during editing; reopen Aliases and retry.'
        return 1
    fi
    if ! mv -f -- "$temp" "$path" 2>/dev/null; then
        rm -f -- "$temp" "$snapshot"
        ALIAS_ERROR='Could not replace ~/.bashrc; check home permissions (original intact).'
        return 1
    fi
    rm -f -- "$snapshot"
}

alias_valid_name() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

alias_valid_command() {
    [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

alias_save_entry() {
    local old_index=$1 name=$2 value=$3 i
    if ! alias_valid_name "$name" || ! alias_valid_command "$value"; then
        ALIAS_ERROR='Use a Bash identifier and a nonempty, single-line command.'
        return 1
    fi
    for i in "${!ALIAS_NAMES[@]}"; do
        if [[ "${ALIAS_NAMES[$i]}" == "$name" ]] && ((i != old_index)); then
            ALIAS_ERROR="Alias '$name' already exists in the managed block."
            return 1
        fi
    done
    if ((old_index < 0)); then
        ALIAS_NAMES+=("$name")
        ALIAS_COMMANDS+=("$value")
    else
        ALIAS_NAMES[$old_index]=$name
        ALIAS_COMMANDS[$old_index]=$value
    fi
    alias_profile_write
}

alias_delete_entry() {
    local index=$1 i
    local -a names=() commands=()
    for i in "${!ALIAS_NAMES[@]}"; do
        if ((i != index)); then
            names+=("${ALIAS_NAMES[$i]}")
            commands+=("${ALIAS_COMMANDS[$i]}")
        fi
    done
    ALIAS_NAMES=("${names[@]}")
    ALIAS_COMMANDS=("${commands[@]}")
    alias_profile_write
}

# Import only canonical, literal alias lines; never execute the file. Validate
# the entire input (including bytes Bash's read would discard) before editing.
alias_import_file() {
    local path=${ALIAS_CONFIG_FILE:-./bash-aliases.conf} temp line plain name raw decoded encoded index=0
    local escape="'\\''" complete=1
    local -a additions_names=() additions_commands=()
    local -a original_names=("${ALIAS_NAMES[@]}") original_commands=("${ALIAS_COMMANDS[@]}")
    local -A seen=() skipped=()
    ALIAS_ERROR=""
    ALIAS_SKIPPED_NAMES=()
    ALIAS_IMPORTED_COUNT=0
    if [[ -L "$path" || ! -f "$path" || ! -r "$path" ]]; then
        ALIAS_ERROR='Import needs a readable, regular ./bash-aliases.conf (no symlinks).'
        return 1
    fi
    if ! temp=$(mktemp "${TMPDIR:-/tmp}/tunnelwizard-alias-import.XXXXXX" 2>/dev/null); then
        ALIAS_ERROR='Cannot validate the import file; check temporary-file permissions.'
        return 1
    fi
    for name in "${ALIAS_NAMES[@]}"; do seen[$name]=1; done
    while true; do
        if IFS= read -r line; then
            complete=1
        elif [[ -n "$line" ]]; then
            complete=0
        else
            break
        fi
        index=$((index + 1))
        if ! { printf '%s' "$line" &&
               { if ((complete)); then printf '\n'; fi; }; } >> "$temp"; then
            ALIAS_ERROR='Cannot validate the import file; check free space.'
            break
        fi
        plain=${line%$'\r'}
        if [[ "$plain" =~ ^[[:space:]]*(#.*)?$ ]]; then
            :
        elif [[ "$plain" =~ ^alias[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)=\'(.*)\'$ ]]; then
            name=${BASH_REMATCH[1]}
            raw=${BASH_REMATCH[2]}
            decoded=${raw//"$escape"/\'}
            encoded=${decoded//\'/"$escape"}
            if [[ "$plain" != "alias $name='$encoded'" ]] || ! alias_valid_command "$decoded"; then
                ALIAS_ERROR="Invalid canonical alias on line $index of ./bash-aliases.conf; nothing imported."
                break
            fi
            if [[ -n "${seen[$name]:-}" ]]; then
                if [[ -z "${skipped[$name]:-}" ]]; then
                    ALIAS_SKIPPED_NAMES+=("$name")
                    skipped[$name]=1
                fi
            else
                seen[$name]=1
                additions_names+=("$name")
                additions_commands+=("$decoded")
            fi
        else
            ALIAS_ERROR="Invalid canonical alias on line $index of ./bash-aliases.conf; nothing imported."
            break
        fi
        ((complete)) || break
    done < "$path"
    if [[ -z "$ALIAS_ERROR" ]] &&
       { [[ -L "$path" ]] || ! cmp -s -- "$path" "$temp"; }; then
        ALIAS_ERROR='Import file changed or contains unsupported bytes; nothing imported.'
    fi
    rm -f -- "$temp"
    [[ -z "$ALIAS_ERROR" ]] || return 1
    ALIAS_IMPORTED_COUNT=${#additions_names[@]}
    if ((ALIAS_IMPORTED_COUNT)); then
        ALIAS_NAMES+=("${additions_names[@]}")
        ALIAS_COMMANDS+=("${additions_commands[@]}")
        if ! alias_profile_write; then
            ALIAS_NAMES=("${original_names[@]}")
            ALIAS_COMMANDS=("${original_commands[@]}")
            ALIAS_IMPORTED_COUNT=0
            return 1
        fi
    fi
}

# An existing export requires the checksum captured before the user's explicit
# overwrite confirmation. Compare a snapshot again immediately before replace.
alias_export_file() {
    local expected=${1:-} path=${ALIAS_CONFIG_FILE:-./bash-aliases.conf} temp snapshot='' name encoded index write_ok=1
    local escape="'\\''"
    ALIAS_ERROR=""
    if [[ -L "$path" || ( -e "$path" && ( ! -f "$path" || ! -r "$path" ) ) ]]; then
        ALIAS_ERROR='Export target must be a readable regular file (no symlinks).'
        return 1
    fi
    if [[ -e "$path" && -z "$expected" ]]; then
        ALIAS_ERROR='Confirm overwriting the existing ./bash-aliases.conf first.'
        return 1
    fi
    if [[ ! -e "$path" && -n "$expected" ]]; then
        ALIAS_ERROR='Export target changed since confirmation; retry.'
        return 1
    fi
    if ! temp=$(mktemp "$path.tunnelwizard.XXXXXX" 2>/dev/null); then
        ALIAS_ERROR='Cannot create a temporary export beside ./bash-aliases.conf.'
        return 1
    fi
    if [[ -e "$path" ]]; then
        if ! snapshot=$(mktemp "$path.tunnelwizard.XXXXXX" 2>/dev/null) ||
           ! cp -p -- "$path" "$snapshot" 2>/dev/null ||
           [[ "$(cksum < "$snapshot" 2>/dev/null)" != "$expected" ]]; then
            rm -f -- "$temp" ${snapshot:+"$snapshot"}
            ALIAS_ERROR='Export target changed since confirmation or cannot be read; retry.'
            return 1
        fi
        if ! cp -p -- "$snapshot" "$temp" 2>/dev/null; then
            rm -f -- "$temp" "$snapshot"
            ALIAS_ERROR='Cannot prepare the export; existing file was not changed.'
            return 1
        fi
    fi
    if ! {
        if ((${#ALIAS_NAMES[@]} == 0)); then
            printf '# TunnelWizard Bash aliases export (no aliases)\n'
        fi
        for index in "${!ALIAS_NAMES[@]}"; do
            name=${ALIAS_NAMES[$index]}
            encoded=${ALIAS_COMMANDS[$index]//\'/"$escape"}
            if ! printf "alias %s='%s'\n" "$name" "$encoded"; then
                write_ok=0
                break
            fi
        done
        ((write_ok))
    } > "$temp"; then
        rm -f -- "$temp" ${snapshot:+"$snapshot"}
        ALIAS_ERROR='Cannot write the temporary export; existing file was not changed.'
        return 1
    fi
    if [[ -L "$path" ]] ||
       { [[ -n "$snapshot" ]] && ! cmp -s -- "$path" "$snapshot"; } ||
       { [[ -z "$snapshot" && -e "$path" ]]; }; then
        rm -f -- "$temp" ${snapshot:+"$snapshot"}
        ALIAS_ERROR='Export target changed during writing; retry.'
        return 1
    fi
    if ! mv -f -- "$temp" "$path" 2>/dev/null; then
        rm -f -- "$temp" ${snapshot:+"$snapshot"}
        ALIAS_ERROR='Could not replace the export; existing file was not changed.'
        return 1
    fi
    [[ -z "$snapshot" ]] || rm -f -- "$snapshot"
}

alias_clear_all() {
    ALIAS_ERROR=""
    ((${#ALIAS_NAMES[@]})) || return 0
    local -a original_names=("${ALIAS_NAMES[@]}") original_commands=("${ALIAS_COMMANDS[@]}")
    ALIAS_NAMES=()
    ALIAS_COMMANDS=()
    if ! alias_profile_write; then
        ALIAS_NAMES=("${original_names[@]}")
        ALIAS_COMMANDS=("${original_commands[@]}")
        return 1
    fi
}
