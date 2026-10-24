# SSH Tunnel Wizard

A Bash terminal UI for starting and monitoring SSH tunnels. It also displays
saved SSH shells and can open them in separate WezTerm windows.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- An interactive terminal
- WezTerm, with the `wezterm` command available in your Bash `PATH`, if you
  want to open saved shells

## Setup

1. Save the script as `tunnels.sh` and make it executable:

   ```bash
   chmod +x tunnels.sh
   ```

2. Copy the example config and replace its placeholder values:

   ```bash
   cp tunnels.conf.example tunnels.conf
   ```

3. Start the wizard:

   ```bash
   ./tunnels.sh ./tunnels.conf
   ```

Without a config argument, the script reads `~/.ssh/tunnels.conf`.

> **Security:** The config file is sourced as Bash code. Only use a config
> you trust.

## Configuration

Declare a machine, followed by its tunnels:

```bash
machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
tunnel DISPLAY_NAME LOCAL_FORWARD
```

- `ALIAS` is a descriptive machine name.
- `SSH_HOST` and `SSH_USER` identify the SSH server and account.
- `IDENTITY_FILE` is the SSH private-key path.
- `GROUP=yes` runs that machine's forwards through one SSH process.
- `GROUP=no` starts a separate SSH process for each forward.
- `LOCAL_FORWARD` uses a form such as
  `LOCAL_PORT:DEST_HOST:DEST_PORT`.

Saved SSH shells use:

```bash
shell DISPLAY_NAME SSH_TARGET
```

`SSH_TARGET` can be a `user@host` target or an SSH alias understood by your
SSH setup. See `tunnels.conf.example` for a template.

## Controls

### Start page

| Key | Action |
| --- | --- |
| `1`–`9` | Open the corresponding saved shell |
| Arrow keys | Select among the first nine saved shells |
| `Enter` | Open the selected shell |
| `S` | Open the full saved-shell menu |
| `Ctrl+R` | Stop and restart the tunnels |
| `Ctrl+C` | Stop tracked tunnel processes and exit |

### Saved-shell menu

| Key | Action |
| --- | --- |
| `1`–`9` | Open the corresponding saved shell |
| Arrow keys | Change the selection |
| `Enter` | Open the selected shell |
| `Esc` or `Q` | Return to the start page |

The start page shows up to nine shells. The `S` menu provides access to the
full list.

## WezTerm

Saved shells open through the `wezterm` command-line tool. Make sure
`wezterm` is available in the `PATH` seen by the Bash process running the
wizard.

You can use your own WezTerm Lua configuration file, or adapt
`wezterm.lua.example`. The desktop shortcut below passes a Lua config to
WezTerm with `--config-file`.

## Windows desktop shortcut

With WezTerm and Git for Windows installed, create a desktop shortcut and
set its **Target** to:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" --config-file "C:\Users\<WINDOWS_USER>\.ssh\tunnels.lua" start --cwd "C:\Users\<WINDOWS_USER>\.ssh" -- "C:\Program Files\Git\bin\bash.exe" -c "./tunnels.sh ./tunnels.conf"
```

Replace `<WINDOWS_USER>` with your Windows account folder name. Check that
the WezTerm and Git Bash executable paths match your installations.

This command expects `tunnels.sh` and `tunnels.conf` in your `.ssh` directory.
If you keep them elsewhere, change `--cwd` and the Bash command accordingly.
It also expects your Lua config at the specified `tunnels.lua` path; change
that path or omit `--config-file` if you use WezTerm's default configuration.

## Repository safety

Commit `tunnels.conf.example`, but avoid committing your real
`tunnels.conf`, private keys, or credentials. For example, add this to
`.gitignore` if your real config is stored in the repository directory:

```gitignore
tunnels.conf
```
