#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/aliases-manager.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
home_dir=$(mktemp -d)
trap 'rm -rf -- "$home_dir"' EXIT
HOME=$home_dir
profile=$HOME/.bashrc
printf '%s\n' '# leave this alone' '# Notes about TunnelWizard Bash aliases outside the managed block' \
    'alias outside="unchanged"' > "$profile"
printf '%s' 'export CUSTOM=value' >> "$profile"
original=$(cat "$profile")
alias_profile_read || fail "$ALIAS_ERROR"
[[ ${#ALIAS_NAMES[@]} -eq 0 ]] || fail 'read aliases outside the managed block'
alias_save_entry -1 op './script-that-opens-wezterm.sh' || fail "$ALIAS_ERROR"
alias_profile_read || fail "$ALIAS_ERROR"
[[ ${ALIAS_NAMES[0]} == op && ${ALIAS_COMMANDS[0]} == './script-that-opens-wezterm.sh' ]] || fail 'round trip failed'
[[ $(cat "$profile") == "$original"$'\n'* ]] || fail 'unrelated content was changed'
alias_save_entry -1 xxx exit || fail "$ALIAS_ERROR"
alias_profile_read || fail "$ALIAS_ERROR"
alias_save_entry 0 op 'printf "it'"'"'s okay"' || fail "$ALIAS_ERROR"
alias_profile_read || fail "$ALIAS_ERROR"
[[ ${ALIAS_COMMANDS[0]} == 'printf "it'"'"'s okay"' && ${ALIAS_NAMES[1]} == xxx ]] || fail 'quoted commands did not round trip'
actual=$(HOME="$HOME" bash --noprofile --rcfile "$profile" -ic op 2>/dev/null)
[[ "$actual" == "it's okay" ]] || fail 'managed alias did not execute from an interactive Bash profile'
[[ $(grep -c '^# >>> TunnelWizard Bash aliases >>>$' "$profile") -eq 1 ]] || fail 'more than one block created'
if alias_save_entry -1 xxx 'echo duplicate'; then fail 'duplicate name accepted'; fi
if alias_save_entry -1 bad 'bad'$'\n''line'; then fail 'multiline command accepted'; fi
alias_delete_entry 0 || fail "$ALIAS_ERROR"
alias_profile_read || fail "$ALIAS_ERROR"
[[ ${#ALIAS_NAMES[@]} -eq 1 && ${ALIAS_NAMES[0]} == xxx ]] || fail 'edit/delete affected other aliases'
alias_delete_entry 0 || fail "$ALIAS_ERROR"
[[ $(cat "$profile") == "$original" ]] || fail 'deletion damaged unrelated content'

printf '%s\n' '# >>> TunnelWizard Bash aliases >>>' 'alias op="not canonical"' '# <<< TunnelWizard Bash aliases <<<' > "$profile"
before=$(cat "$profile")
if alias_profile_read; then fail 'malformed block accepted'; fi
[[ -n $ALIAS_ERROR && $(cat "$profile") == "$before" ]] || fail 'malformed block changed the file'
printf '%s\n' '# >>> TunnelWizard Bash aliases >>>' "alias op='echo hi'" > "$profile"
if alias_profile_read; then fail 'unclosed block accepted'; fi
printf '%s\n' '# >>> TunnelWizard Bash aliases >>>' '# <<< TunnelWizard Bash aliases <<<' \
    '# >>> TunnelWizard Bash aliases >>>' '# <<< TunnelWizard Bash aliases <<<' > "$profile"
if alias_profile_read; then fail 'duplicate block accepted'; fi
printf '%s\n' '# >>> TunnelWizard Bash aliases >>> ' > "$profile"
if alias_profile_read; then fail 'malformed marker accepted'; fi

printf '%s\n' 'unrelated' '$(touch "$HOME/should-not-exist")' > "$profile"
alias_profile_read || fail "$ALIAS_ERROR"
[[ ! -e "$HOME/should-not-exist" ]] || fail '.bashrc was sourced while reading aliases'
printf '%s\n' 'changed elsewhere' >> "$profile"
if alias_save_entry -1 op exit; then fail 'stale profile was overwritten'; fi
[[ $(tail -n 1 "$profile") == 'changed elsewhere' ]] || fail 'external change lost'
alias_profile_read || fail "$ALIAS_ERROR"
mv() { return 1; }
if alias_save_entry -1 op exit; then fail 'failed replacement was reported as success'; fi
unset -f mv
[[ $(tail -n 1 "$profile") == 'changed elsewhere' && ! -e "$HOME/should-not-exist" ]] ||
    fail 'failed replacement changed profile or sourced it'
printf 'first\000second\n' > "$profile"
alias_profile_read || fail "$ALIAS_ERROR"
if alias_save_entry -1 op exit; then fail 'binary profile was silently rewritten'; fi
[[ -n "$ALIAS_ERROR" ]] || fail 'binary profile refusal lacks diagnostic'
printf 'export A=1\r\nexport B=2\r\n' > "$profile"
alias_profile_read || fail "$ALIAS_ERROR"
alias_save_entry -1 xxx exit || fail "$ALIAS_ERROR"
alias_profile_read || fail "$ALIAS_ERROR"
alias_delete_entry 0 || fail "$ALIAS_ERROR"
[[ $(cat "$profile") == $'export A=1\r\nexport B=2\r' ]] || fail 'CRLF profile content changed'
printf 'first LF\nsecond CRLF\r\n' > "$profile"
alias_profile_read || fail "$ALIAS_ERROR"
alias_save_entry -1 xxx exit || fail "$ALIAS_ERROR"
printf 'first LF\nsecond CRLF\r\n# >>> TunnelWizard Bash aliases >>>\r\nalias xxx=\047exit\047\r\n# <<< TunnelWizard Bash aliases <<<\r\n' > "$HOME/expected"
cmp -s "$HOME/expected" "$profile" || fail 'mixed-ending profile used inconsistent managed-block line endings'
mv "$profile" "$HOME/original"
ln -s original "$profile"
if alias_profile_read; then fail 'symlink profile accepted'; fi
[[ -n $ALIAS_ERROR ]] || fail 'symlink refusal lacks diagnostic'

rm -- "$profile"
mkdir "$HOME/work"
cd "$HOME/work"
printf '%s\n' 'export PRESERVED=1' 'alias outside="untouched"' > "$profile"
alias_profile_read || fail "$ALIAS_ERROR"
alias_save_entry -1 op 'echo original' || fail "$ALIAS_ERROR"
alias_profile_read || fail "$ALIAS_ERROR"
printf '%s\n' '# portable aliases' '' "alias op='echo duplicate'" \
    "alias fresh='printf \"it'\\''s okay\"'" "alias fresh='echo ignored'" \
    "alias second='exit'" "alias second='echo ignored too'" > bash-aliases.conf
alias_import_file || fail "$ALIAS_ERROR"
[[ $ALIAS_IMPORTED_COUNT -eq 2 && ${#ALIAS_SKIPPED_NAMES[@]} -eq 3 &&
   ${ALIAS_SKIPPED_NAMES[0]} == op && ${ALIAS_SKIPPED_NAMES[1]} == fresh &&
   ${ALIAS_SKIPPED_NAMES[2]} == second ]] || fail 'duplicate import did not report exact skipped names'
alias_profile_read || fail "$ALIAS_ERROR"
[[ ${#ALIAS_NAMES[@]} -eq 3 && ${ALIAS_COMMANDS[0]} == 'echo original' &&
   ${ALIAS_NAMES[1]} == fresh && ${ALIAS_COMMANDS[1]} == 'printf "it'"'"'s okay"' &&
   ${ALIAS_NAMES[2]} == second && ${ALIAS_COMMANDS[2]} == exit ]] ||
    fail 'duplicate import did not preserve first valid occurrences'
actual=$(HOME="$HOME" bash --noprofile --rcfile "$profile" -ic fresh 2>/dev/null)
[[ "$actual" == "it's okay" ]] || fail 'imported quote escaping did not execute correctly'
before=$(cat "$profile")
alias_import_file || fail "$ALIAS_ERROR"
[[ $ALIAS_IMPORTED_COUNT -eq 0 && ${#ALIAS_SKIPPED_NAMES[@]} -eq 3 &&
   ${ALIAS_SKIPPED_NAMES[0]} == op && ${ALIAS_SKIPPED_NAMES[1]} == fresh &&
   ${ALIAS_SKIPPED_NAMES[2]} == second && $(cat "$profile") == "$before" ]] ||
    fail 'repeat import was not a no-op with exact duplicate names'

printf '%s\n' "alias good='echo good'" 'alias bad="not canonical"' > bash-aliases.conf
if alias_import_file; then fail 'malformed import accepted'; fi
[[ $ALIAS_ERROR == *'line 2'* && $(cat "$profile") == "$before" ]] ||
    fail 'malformed import made partial profile changes or lacked a line diagnostic'
printf '%s\n' "alias good='echo good'" '$(touch "$HOME/should-not-exist")' > bash-aliases.conf
if alias_import_file; then fail 'executable import line accepted'; fi
[[ ! -e "$HOME/should-not-exist" && $(cat "$profile") == "$before" ]] ||
    fail 'import executed code or changed the profile on failure'
printf '# comment\000unsafe\n' > bash-aliases.conf
if alias_import_file; then fail 'NUL in import was silently discarded'; fi
[[ $(cat "$profile") == "$before" ]] || fail 'binary import changed the profile'
printf '%s\n' "alias good='echo good'" > bash-aliases.conf
mv() { return 1; }
if alias_import_file; then fail 'failed import profile write reported success'; fi
unset -f mv
[[ $(cat "$profile") == "$before" && ${#ALIAS_NAMES[@]} -eq 3 ]] ||
    fail 'failed import write changed profile or in-memory aliases'
rm -- bash-aliases.conf
ln -s "$profile" bash-aliases.conf
if alias_import_file; then fail 'symlink import accepted'; fi
if alias_export_file; then fail 'symlink export accepted'; fi
rm -- bash-aliases.conf

alias_export_file || fail "$ALIAS_ERROR"
printf '%s\n' "alias op='echo original'" \
    "alias fresh='printf \"it'\\''s okay\"'" "alias second='exit'" > "$HOME/expected"
cmp -s "$HOME/expected" bash-aliases.conf || fail 'export did not use canonical quoted alias lines'
if alias_export_file; then fail 'existing export overwritten without confirmation'; fi
cmp -s "$HOME/expected" bash-aliases.conf || fail 'unconfirmed export changed file'
checksum=$(cksum < bash-aliases.conf)
printf '%s\n' 'manual edit' > bash-aliases.conf
if alias_export_file "$checksum"; then fail 'stale export confirmation was accepted'; fi
[[ $(cat bash-aliases.conf) == 'manual edit' ]] || fail 'stale export damaged target'
checksum=$(cksum < bash-aliases.conf)
mv() { return 1; }
if alias_export_file "$checksum"; then fail 'failed export replacement reported success'; fi
unset -f mv
[[ $(cat bash-aliases.conf) == 'manual edit' ]] || fail 'failed export damaged existing file'
alias_export_file "$checksum" || fail "$ALIAS_ERROR"
cmp -s "$HOME/expected" bash-aliases.conf || fail 'confirmed overwrite failed'
alias_save_entry -1 later 'echo later' || fail "$ALIAS_ERROR"
cmp -s "$HOME/expected" bash-aliases.conf || fail 'export was automatically synced'
alias_profile_read || fail "$ALIAS_ERROR"
alias_clear_all || fail "$ALIAS_ERROR"
printf '%s\n' 'export PRESERVED=1' 'alias outside="untouched"' > "$HOME/expected-profile"
cmp -s "$HOME/expected-profile" "$profile" || fail 'clear all damaged outside profile content'
alias_profile_read || fail "$ALIAS_ERROR"
alias_clear_all || fail "$ALIAS_ERROR"
cmp -s "$HOME/expected-profile" "$profile" || fail 'empty clear all changed the profile'
alias_import_file || fail "$ALIAS_ERROR"
[[ $ALIAS_IMPORTED_COUNT -eq 3 && ${#ALIAS_SKIPPED_NAMES[@]} -eq 0 ]] ||
    fail 'export/import round trip did not restore aliases'
alias_profile_read || fail "$ALIAS_ERROR"
[[ ${#ALIAS_NAMES[@]} -eq 3 && ${ALIAS_COMMANDS[1]} == 'printf "it'"'"'s okay"' ]] ||
    fail 'export/import round trip lost quoted commands'

before=$(cat "$profile")
mv() { return 1; }
if alias_clear_all; then fail 'failed clear-all profile write reported success'; fi
unset -f mv
[[ $(cat "$profile") == "$before" && ${#ALIAS_NAMES[@]} -eq 3 ]] ||
    fail 'failed clear all changed profile or in-memory aliases'
rm -- bash-aliases.conf
mkdir bash-aliases.conf
if alias_export_file; then fail 'directory export target accepted'; fi
rmdir bash-aliases.conf
{
    for ((i = 0; i < 50; i++)); do
        printf "alias skipped_%02d='echo first'\n" "$i"
        printf "alias skipped_%02d='echo later'\n" "$i"
    done
} > bash-aliases.conf
alias_import_file || fail "$ALIAS_ERROR"
[[ $ALIAS_IMPORTED_COUNT -eq 50 && ${#ALIAS_SKIPPED_NAMES[@]} -eq 50 &&
   ${ALIAS_SKIPPED_NAMES[0]} == skipped_00 &&
   ${ALIAS_SKIPPED_NAMES[49]} == skipped_49 ]] ||
    fail 'many skipped aliases were truncated or did not retain exact names'
ALIAS_CONFIG_FILE="$HOME/work/bash-aliases.conf"
cd "$HOME"
alias_import_file || fail "$ALIAS_ERROR"
[[ $ALIAS_IMPORTED_COUNT -eq 0 && ${#ALIAS_SKIPPED_NAMES[@]} -eq 50 ]] ||
    fail 'alias file did not stay in the launch directory after changing cwd'
cd "$HOME/work"
unset ALIAS_CONFIG_FILE
alias_profile_read || fail "$ALIAS_ERROR"
printf 'external edit\n' >> "$profile"
printf '%s\n' "alias new_one='echo new'" > bash-aliases.conf
if alias_import_file; then fail 'stale profile was overwritten by import'; fi
[[ $(tail -n 1 "$profile") == 'external edit' ]] || fail 'import lost a concurrent profile edit'
alias_profile_read || fail "$ALIAS_ERROR"
printf '%s\n' 'alias literal='"'"'$(touch "$HOME/should-not-exist")'"'"'' > bash-aliases.conf
alias_import_file || fail "$ALIAS_ERROR"
[[ ! -e "$HOME/should-not-exist" ]] || fail 'valid import was evaluated instead of parsed'
alias_profile_read || fail "$ALIAS_ERROR"
printf "alias windows='echo imported-from-crlf'\r\n" > bash-aliases.conf
alias_import_file || fail "$ALIAS_ERROR"
last_index=$((${#ALIAS_NAMES[@]} - 1))
[[ ${ALIAS_NAMES[$last_index]} == windows && ${ALIAS_COMMANDS[$last_index]} == 'echo imported-from-crlf' ]] ||
    fail 'CRLF import was not parsed correctly'
alias_profile_read || fail "$ALIAS_ERROR"
alias_clear_all || fail "$ALIAS_ERROR"
rm -- bash-aliases.conf
alias_export_file || fail "$ALIAS_ERROR"
[[ $(cat bash-aliases.conf) == '# TunnelWizard Bash aliases export (no aliases)' ]] ||
    fail 'empty export did not explain that it contains no aliases'

printf 'Alias-block management tests passed.\n'
