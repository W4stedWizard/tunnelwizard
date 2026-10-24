# SSH Tunnel Wizard

A Bash terminal UI for starting and monitoring SSH tunnels, with saved SSH
shell connections that open in separate terminal windows.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- An interactive terminal
- `base64`, for opening saved shells through a system terminal

WezTerm is optional. On Windows, the non-WezTerm window fallback uses
PowerShell and Git for Windows. On macOS it uses Terminal. On Linux it looks
for `xdg-terminal-exec` or `x-terminal-emulator`.

## Get started

Clone the repository or download and extract its ZIP. Keep the project files
together in the resulting folder:

```text
ssh-tunnel-wizard/
├── README.md
├── tunnels.sh
├── tunnels.conf.example
├── tunnels.conf          # Your local copy; do not commit it
└── tunnels.lua           # Optional: your WezTerm Lua config
```

From the project folder, create your personal config:

```bash
cp tunnels.conf.example tunnels.conf
```

Edit `tunnels.conf` with your hosts, usernames, forwards, and SSH key paths.
Then start the wizard:

```bash
bash ./tunnels.sh
```

Using `bash ./tunnels.sh` also works when extracting a ZIP has not preserved
the script's executable bit.

**By default, the script reads `tunnels.conf` beside `tunnels.sh`.** You can
launch the script from another directory and it will still find that config.

To use a different config, pass its path explicitly:

```bash
bash ./tunnels.sh /path/to/another.conf
```

An explicitly supplied relative path is interpreted relative to your
current working directory.

> **Security:** The script sources its config as Bash code. Only use a
> config file you trust.

## Configuration

Define a machine followed by its tunnels:

```bash
machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
tunnel DISPLAY_NAME LOCAL_FORWARD
```

Each `tunnel` belongs to the most recently declared `machine`.

- `ALIAS`: descriptive machine name.
- `SSH_HOST`: SSH server hostname or address.
- `SSH_USER`: SSH username.
- `IDENTITY_FILE`: SSH private-key path. For example,
  `~/.ssh/id_ed25519` keeps the key outside the project folder.
- `GROUP=yes`: share one SSH process for that machine's forwards.
- `GROUP=no`: start a separate SSH process for each forward.
- `LOCAL_FORWARD`: a local forward such as `8080:127.0.0.1:80`.

Add saved SSH shells with:

```bash
shell DISPLAY_NAME SSH_TARGET
```

`SSH_TARGET` can be `user@host` or an SSH alias understood by your SSH
setup. See `tunnels.conf.example` for a template.

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

The start page shows up to nine shells. The `S` menu provides access to
the full list.

## Where saved shells open

The wizard detects whether it is running inside WezTerm.

- **Inside WezTerm:** it uses `wezterm cli spawn --new-window`, preserving
  the existing WezTerm-specific title variable. The `wezterm` command must
  be available in Bash's `PATH`.
- **Outside WezTerm on Windows:** it launches Git Bash as a new console
  application through PowerShell. Windows chooses the window according to
  its configured default console terminal host.
- **Outside WezTerm on macOS:** it opens the session in Apple's Terminal app.
- **Outside WezTerm on Linux:** it tries `xdg-terminal-exec`, then
  `x-terminal-emulator`.

If the WezTerm CLI fails, the wizard also tries the operating-system
fallback. If no supported window launcher is available, it runs the SSH
session in the wizard's current window and returns to the wizard when that
session ends.

The dashboard reports a successful new-window request as
`Opened 'NAME' in new window.` A launcher accepting a request does not,
by itself, verify that the remote SSH login succeeded.

## WezTerm configuration

A custom WezTerm Lua config is optional. If you use one, you can keep
`tunnels.lua` in the project folder and pass it with `--config-file`.
Otherwise, omit that option to use your normal WezTerm configuration.

The WezTerm-specific shell-window title variable is named
`SSH_WIZARD_TITLE`. Your Lua configuration can use it if you have set up
custom window titles.

SSH private keys do not need to be in the project folder; they can remain
in your normal `~/.ssh` directory.

## Windows desktop shortcut

With WezTerm and Git for Windows installed, create a desktop shortcut.
For a project extracted or cloned to
`C:\Users\\Projects\ssh-tunnel-wizard`, set the shortcut's
**Target** to:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" --config-file "C:\Users\\Projects\ssh-tunnel-wizard\tunnels.lua" start --cwd "C:\Users\\Projects\ssh-tunnel-wizard" -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./tunnels.sh"
```

Replace `` with your account folder name and adjust paths
to match your installation. This version assumes that `tunnels.lua` exists
at the specified location.

Without a custom Lua config, use:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" start --cwd "C:\Users\\Projects\ssh-tunnel-wizard" -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./tunnels.sh"
```

The shortcut starts the wizard **inside WezTerm**, so saved shells use
WezTerm's new-window behavior. If you instead start the wizard in another
terminal, it uses the operating-system fallback described above.

The `--cwd` option lets the shortcut run the short command
`bash ./tunnels.sh`. Once started, the script locates its default config
beside itself.
