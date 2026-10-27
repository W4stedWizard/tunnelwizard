# SSH Tunnel Wizard

A Bash terminal UI for starting and monitoring SSH tunnels, with saved SSH
shell connections that open in separate terminal windows.

<img width="728" height="493" alt="image" src="https://github.com/user-attachments/assets/5385af21-4180-409a-8a78-52d8889cb266" />

## Requirements

- Bash
- OpenSSH client (`ssh`)
- An interactive terminal
- `base64`, for opening saved shells through a system terminal

WezTerm is optional. On Windows, the non-WezTerm window fallback uses
PowerShell and Git for Windows. On macOS it uses Terminal. On Linux it looks
for `xdg-terminal-exec` or `x-terminal-emulator`.
The opt-in Windows hosts menu uses Windows PowerShell, `cygpath` and `readlink`
(provided with Git for Windows); it does not need third-party hashing tools.

## Get started

Clone the repository or download and extract its ZIP. Keep the project files
together in the resulting folder:

```text
ssh-tunnel-wizard/
├── README.md
├── tunnels.sh
├── hosts-manager.ps1     # Windows-only, on-demand hosts-file helper
├── tunnels.conf.example
├── tunnels.conf          # Your local copy; do not commit it
├── ssh_config.example
├── ssh_config             # Optional local OpenSSH config; do not commit it
└── tunnels.lua           # Optional: your WezTerm Lua config
```

From the project folder, create your TunnelWizard config:

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

To load a project-local OpenSSH client config, copy the example as well:

```bash
cp ssh_config.example ssh_config
```

`ssh_config` is optional and is automatically loaded for all tunnel and
saved-shell SSH connections when it exists beside `tunnels.sh`. It uses standard
OpenSSH client configuration syntax. TunnelWizard supplies the tunnel's
target, username, identity file, and port-forward options on the SSH command
line; the custom file is useful for settings such as `ProxyJump`, `HostName`,
keepalives, and additional host matching.

Because TunnelWizard passes this file with OpenSSH's `-F` option, it replaces
the usual per-user and system-wide SSH config files rather than merging with
them automatically. Add `Include ~/.ssh/config` to `ssh_config` if you want
to reuse your normal per-user settings. See the official
[OpenSSH client configuration reference](https://man.openbsd.org/ssh_config)
and the [`ssh_config.example`](ssh_config.example) template.

## Configuration

Define a machine followed by its tunnels:

```bash
machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
tunnel DISPLAY_NAME LOCAL_FORWARD [LOCAL_HOSTNAME]
hosts_management no
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
- `LOCAL_HOSTNAME` (optional): a DNS-style alias for this local forward. It
  binds to its own `127.x.x.x` loopback address, allowing several hosts to use
  the same local port. Without an explicit bind, TunnelWizard assigns a
  deterministic address. You can instead choose a specific loopback address
  in the four-part forward form (`BIND:LOCAL_PORT:DEST_HOST:DEST_PORT`); it
  then becomes the hostname's address. Existing two-argument tunnels remain
  unchanged. Non-loopback binds and hostname/address collisions are rejected.

### Local hostnames and Windows hosts file

The Windows hosts-file UI is **off by default**. Add `hosts_management yes` to
the selected `.conf` to make the `H` menu available. Opting in does **not**
change hosts on startup, when restarting tunnels, or on exit. In the `H` menu,
choose `A` to preview the exact lines removed and added when syncing this
config's aliases; confirm to request a one-time UAC prompt for only the hosts
edit. Choose `R` to preview and remove **this config's** block, including stale
aliases after editing your config. Edits persist after closing the wizard;
removal is also manual. UAC cancellation leaves hosts unchanged. An edit
checks for conflicts and fails if hosts changed after preview; preview again.

Each config owns one marked block identified by a hash of its canonical full
path; the marker also shows its filename. Two configs with the same filename
in different directories do not share a block. The helper refuses malformed
blocks and hostname/loopback conflicts outside the current block and preserves
other configs' blocks and unrelated hosts lines. Only the confirmed hosts
operation elevates; neither the wizard nor SSH runs as administrator. After
**successful edits**, the helper runs `ipconfig /flushdns` automatically and
reports separately if flushing fails. No network reboot is required.

For example, both Proxmox nodes may use local port 443 to reach their remote
port 8006, while browsing distinct local hostnames:

```bash
hosts_management yes
machine proxmox-one pmx-one.example.invalid alice ~/.ssh/id_ed25519 no
tunnel "Proxmox one" 443:127.0.0.1:8006 pmx-one
machine proxmox-two pmx-two.example.invalid alice ~/.ssh/id_ed25519 no
tunnel "Proxmox two" 443:127.0.0.1:8006 pmx-two
```

After confirming `H` → `A`, use `https://pmx-one` and `https://pmx-two`.
Alternatively use `8006:127.0.0.1:8006 pmx-one` to browse
`https://pmx-one:8006`. Your browser may warn that a Proxmox certificate does
not match the local alias; configure a trusted matching certificate if needed.
On macOS/Linux, hostnames still bind to their own loopback addresses, but the
Windows hosts UI is unavailable: create matching aliases in your OS's hosts
file or DNS manually. Even on Windows, manually maintained aliases work
without enabling hosts management.

Focused checks are available with `bash tests/test-hostnames.sh`; on Windows,
run `powershell.exe -NoProfile -File tests/test-hosts-plan.ps1` for in-memory
hosts-block planning tests. These checks never edit the real hosts file.

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
| `H` | Open Windows hosts management (only with `hosts_management yes`) |
| `Ctrl+R` | Stop and restart the tunnels |
| `Ctrl+C` | Stop tracked tunnel processes and exit |

### Saved-shell menu

| Key | Action |
| --- | --- |
| `1`–`9` | Open the corresponding saved shell |
| Arrow keys | Change the selection |
| `Enter` | Open the selected shell |
| `Esc` or `Q` | Return to the start page |

### Windows hosts menu

| Key | Action |
| --- | --- |
| `A` | Preview and explicitly confirm sync of this config's aliases |
| `R` | Preview and explicitly confirm removal of this config's block |
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

See the official [WezTerm configuration files documentation](https://wezterm.org/config/files.html)
for the Lua config format.

The WezTerm-specific shell-window title variable is named
`SSH_WIZARD_TITLE`. Your Lua configuration can use it if you have set up
custom window titles.

SSH private keys do not need to be in the project folder; they can remain
in your normal `~/.ssh` directory.

## Windows desktop shortcut

With WezTerm and Git for Windows installed, create a desktop shortcut. Set
its **Start in** field to your project folder, for example:

```text
C:\Users\YourName\Projects\ssh-tunnel-wizard
```

Then set **Target** to:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" --config-file "tunnels.lua" start --cwd . -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./tunnels.sh"
```

The project folder is entered only once, in **Start in**. `--cwd .` tells
WezTerm to start the initial terminal in that folder, so the relative
`tunnels.lua` and `bash ./tunnels.sh` paths resolve there. Adjust the WezTerm
and Git Bash paths if they are installed elsewhere. This version assumes that
`tunnels.lua` exists in the project folder.

Without a custom Lua config, use:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" start --cwd . -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./tunnels.sh"
```

The shortcut starts the wizard **inside WezTerm**, so saved shells use
WezTerm's new-window behavior. If you instead start the wizard in another
terminal, it uses the operating-system fallback described above.

The **Start in** field supplies the working directory, so the shortcut can
use `bash ./tunnels.sh` without a long path. Once started, the script locates
its default config beside itself.
