# TunnelWizard user guide

Detailed installation, configuration, security, and platform notes. Run the
shell commands from the project folder unless a section says otherwise.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- An interactive terminal
- `base64`, for opening saved shells or commands through a system terminal
- `cksum` and `cmp`, for safe Bash alias profile updates

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
├── TW.sh
├── TunnelWizard.ico       # Optional Windows shortcut icon
├── aliases-manager.sh   # Host-wide ~/.bashrc alias block management
├── hosts-manager.ps1     # Windows-only, on-demand hosts-file helper
├── docs/
│   └── user-guide.md
├── tests/
│   ├── test-*.sh
│   └── assets/
│       └── tunnelwizard-home-demo.svg
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
bash ./TW.sh
```

Using `bash ./TW.sh` also works when extracting a ZIP has not preserved
the script's executable bit.

**By default, the script reads `tunnels.conf` beside `TW.sh`.** You can
launch the script from another directory and it will still find that config.

To use a different config, pass its path explicitly:

```bash
bash ./TW.sh /path/to/another.conf
```

An explicitly supplied relative path is interpreted relative to your
current working directory. If its name begins with `-`, put `--` before the
path (after any options): `bash ./TW.sh -- ./-tunnels.conf`.

To select a separate OpenSSH client config, pass `--ssh-config` (or its `-cssh`
shorthand) with its path. It works before or after the optional TunnelWizard
config path:

```bash
bash ./TW.sh --ssh-config ~/.ssh/work.conf
bash ./TW.sh /path/to/tunnels.conf -cssh ./ssh/proxmox.conf
```

The SSH config path is also interpreted relative to your current directory
(and a `~/...` path is expanded from your home directory). The default remains
`ssh_config` beside `TW.sh`, when that file exists.

> **Security:** The script sources its config as Bash code. Only use a
> config file you trust.

To create the default project-local OpenSSH client config, copy the example:

```bash
cp ssh_config.example ssh_config
```

`ssh_config` is optional and is automatically loaded for all tunnel and
saved-shell SSH connections when it exists beside `TW.sh`; `--ssh-config`
selects a different file for both. They use standard OpenSSH client
configuration syntax. TunnelWizard supplies the tunnel's target, username,
identity file, and port-forward options on the SSH command line; the custom
file is useful for settings such as `ProxyJump`, `HostName`, keepalives, and
additional host matching. The example includes `~/.ssh/config` by default, so
your usual aliases and options remain available when you copy it.

Because TunnelWizard passes the selected file with OpenSSH's `-F` option, it
replaces the usual per-user and system-wide SSH config files rather than
merging with them automatically. Add an `Include` directive to a custom file
if you want to reuse other SSH settings. See the official
[OpenSSH client configuration reference](https://man.openbsd.org/ssh_config)
and the [`ssh_config.example`](../ssh_config.example) template.

## Configuration

Define a machine followed by its tunnels:

```bash
machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
tunnel DISPLAY_NAME LOCAL_FORWARD [LOCAL_HOSTNAME]
hosts_management no
quick_launch_alt no
name "Priv"
```

Each `tunnel` belongs to the most recently declared `machine`.
The optional `name` directive sets the terminal title to `TW✦ Priv`. Without
it, TunnelWizard uses the config filename without its `.conf` suffix (for
example, `priv.conf` becomes `TW✦ priv`).

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

When configured, the dashboard displays each local hostname beside its forward
in bright text. This reflects the config only; it does not indicate whether a
matching hosts-file or DNS entry is installed.

Press `K` on the dashboard to stop all tracked tunnel subprocesses while
leaving TunnelWizard open. Active tunnel statuses change to `STOPPED`; press
`Ctrl+R` to restart them. The `RUNNING` status is highlighted in purple.
`Ctrl+C` still stops the tunnels and exits the wizard.

When SSH reports a first-use host-key verification failure, TunnelWizard opens
an interactive SSH session in a separate terminal when a supported launcher is
available. The window shows a purple explanation and uses the same SSH host,
user, identity, and SSH config as the tunnel. Review the displayed fingerprint
and accept it only if you have verified it through a trusted source. Once the
session opens, exit it, then type `exit` at the local shell prompt to close the
window. Return to TunnelWizard and choose **Retry**. TunnelWizard does not accept keys or
weaken SSH's configured host-key policy. A changed host key is treated as a
security warning and does not trigger the verification session. If a separate
terminal cannot be opened, connect manually using SSH.

An initial SSH startup failure shows the final line of its error log at the
retry prompt. Enter `S` there to skip retry prompts for all remaining tunnels;
already-running tunnels are left running. If a tunnel exits after startup, the
dashboard currently reports its name and that `Ctrl+R` restarts all tunnels;
the runtime notification does not include the SSH error detail.

### Local hostnames and Windows hosts file

The Windows hosts-file integration is Windows-only. Configured local hostnames
can still be used as loopback aliases on other platforms.

The Windows hosts-file UI is **off by default**. Add `hosts_management yes` to
the selected `.conf` to make the `H` menu available. Opting in does **not**
change hosts on startup, when restarting tunnels, or on exit. Opening the Hosts
page performs an **automatic, read-only check** of the Windows hosts file. A
matching alias maintained by hand also counts as mapped. The check does not
write hosts, flush DNS, or request administrator privileges. Presence is checked
again after each hosts action. The colors describe hosts-file mappings, **not**
DNS cache state or whether an SSH tunnel is running.

**`Ctrl+D` previews deletion of all well-formed TunnelWizard-managed blocks
across every config**, not just
the selected config. It does not delete unrelated hosts-file lines, but it
*will* remove the aliases managed by other TunnelWizard configs, even if you
are currently viewing a different config. Review the full preview and
explicitly confirm the all-config removal before any edit or UAC prompt.

Each config owns one marked block identified by a hash of its canonical full
path; the marker also shows its filename. Two configs with the same filename
in different directories do not share a block. The helper refuses malformed
blocks; syncing also refuses hostname/loopback conflicts outside the current
block. Per-config actions preserve other configs' blocks; the all-config
action removes all valid marked blocks but preserves unrelated hosts lines and
their encoding. Only the confirmed hosts operation elevates; neither the
wizard nor SSH runs as administrator. After **successful edits**, the helper
runs `ipconfig /flushdns` automatically and reports separately if flushing
fails. No network reboot is required.

For example, two Proxmox nodes may use local port 443 to reach their remote
port 8006, while browsing distinct local hostnames:

```bash
hosts_management yes
machine proxmox-one pmx-one.example.invalid alice ~/.ssh/id_ed25519 no
tunnel "Proxmox one" 443:127.0.0.1:8006 pmx-one
machine proxmox-two pmx-two.example.invalid alice ~/.ssh/id_ed25519 no
tunnel "Proxmox two" 443:127.0.0.1:8006 pmx-two
```

After confirming `H` → `A` (Apply), you can load the respective web interfaces
at `https://pmx-one` and `https://pmx-two`.
Your browser may warn that a Proxmox certificate does
not match the local alias; configure a trusted matching certificate if needed.

Add saved SSH shells and local Bash commands to the conf with:

```bash
shell DISPLAY_NAME SSH_TARGET
custom_command DISPLAY_NAME LOCAL_BASH_COMMAND
```

`SSH_TARGET` can be `user@host` or an SSH alias understood by your SSH
setup. For example, `custom_command "Open project" 'cd ~/projects/demo && exec bash'`
launches a local interactive Bash command (it does not run over SSH). Use
quotes around labels or commands containing spaces or shell metacharacters.
The config is sourced as Bash, so quote `$` and other expressions you want
expanded **when the command runs**, not when the config loads. Entries appear
in declaration order, mixing shells and commands in the first nine dashboard
shortcuts and the complete `S` menu. Plain `1`–`9` open entries 1–9. Add
`quick_launch_alt yes` to enable `Alt+1`–`Alt+9` for entries 10–18 (shown as
`A1`–`A9` in the Shells menu); the default is `no`. All later entries remain
available with arrows and Enter in the full Shells menu. Terminal Alt+digit
normally sends Escape followed by the digit; terminals that bind Alt+digits
themselves may need that binding disabled. Ctrl+digit is not used because its
legacy encodings can collide with control keys. Commands do not become tracked
tunnel processes.
See [`tunnels.conf.example`](../tunnels.conf.example).

Press `?` on the dashboard, Shells menu, aliases page, or hosts page for
shortcuts specific to that screen. Press `?`, Esc, or Q to close help and return
to the same selection and scroll position. `Ctrl+R` restarts the tunnels and
`Ctrl+C` exits from any page, including help.

### Host-wide Bash aliases

Press `A` on the dashboard for the separate Bash alias manager. It lists only
aliases in its marked block in `~/.bashrc` (including Git Bash on Windows).
Press `A` to add, `E` to edit a selected name or command, `D` to delete it
(with confirmation), `I` to import, `W` to write an export, or `C` to **Clear
All** managed aliases (with explicit confirmation). Use ↑/↓ to select;
Esc/Q returns. If none are managed, Clear All is a no-op. For example, enter
`op` and `./script-that-opens-wezterm.sh`, or `xxx` and `exit`. Use valid Bash
identifier names, and single-line command values. These aliases are available
in **new interactive Bash sessions outside TunnelWizard**, not just this config;
they are not added to the quick-launch grid. Existing terminal sessions may
need `source ~/.bashrc` or a new terminal to pick up changes. TunnelWizard does
not manage `.zshrc`, source `.bashrc` to display aliases, or change any content
outside its marked block. It refuses malformed/duplicate markers, unexpected
content inside the block, symlinked profiles and failed writes with a message;
edit such a profile manually before retrying.

Import (`I`) reads **`./bash-aliases.conf` from the directory where you launched
TunnelWizard**, not from the directory containing `TW.sh`. Write (`W`)
exports the currently managed aliases to that same path. Both actions use
canonical single-line Bash syntax, for example `alias op='echo hello'`; embedded
single quotes use Bash's ` '\'' ` escaping (without the surrounding spaces).
An import allows empty lines and `#` comments but rejects noncanonical or
malformed lines **without editing the profile**. The file is never sourced or
evaluated. Existing managed names and later occurrences of the same name in
the import are skipped; the first unique definition wins, and a paged report
lists every skipped name. Valid unique entries are saved in one profile update.
Export replaces the file atomically where possible; it refuses symlinks and
non-regular files and asks before overwriting an existing file. An export is
only a snapshot: later alias edits do not update `bash-aliases.conf`, and the
file is not imported again unless you press `I`. Clear All removes only the
TunnelWizard-managed block, preserving the rest of `~/.bashrc`.

## Where saved shells and local commands open

The wizard detects whether it is running inside WezTerm.

- **Inside WezTerm:** it uses `wezterm cli spawn --new-window`; saved SSH
  shells retain their existing WezTerm-specific title variable. The `wezterm`
  command must be available in Bash's `PATH`.
- **Outside WezTerm on Windows:** it launches Git Bash as a new console
  application through PowerShell. Windows chooses the window according to
  its configured default console terminal host.
- **Outside WezTerm on macOS:** it opens the session in Apple's Terminal app.
- **Outside WezTerm on Linux:** it tries `xdg-terminal-exec`, then
  `x-terminal-emulator`.

If the WezTerm CLI fails, the wizard also tries the operating-system
fallback. If no supported window launcher is available, it runs the SSH
session or local command in the wizard's current window and returns when it
ends. Local commands run under interactive Bash and the new window waits for
Enter after the command exits so output remains visible.

Press `N` on the dashboard to open a local interactive shell whose `ssh`
command uses the selected TunnelWizard SSH config. This works with the
available terminal launchers on each supported platform; if no new-window
launcher is available, TunnelWizard reports that rather than replacing the
active dashboard. On Windows/Git Bash the new shell is launched from the
Windows Bash executable path (rather than re-executing an MSYS `/bin/bash`
path); exit that shell to close the new window.

WezTerm's own `Ctrl+Shift+N` new-window shortcut does not inherit the SSH config
selected by a running TunnelWizard session. Use TunnelWizard's `N` shortcut
when you want a new shell with that session's SSH config.

## WezTerm configuration

A custom WezTerm Lua config is optional. If you use one, you can keep
`tunnels.lua` in the project folder and pass it with `--config-file`.
Otherwise, omit that option to use your normal WezTerm configuration.

With the included config, TunnelWizard-created shell windows keep the `✦`
prefix while following the active pane's reported title—for example, an
application title of `OpenCode` appears as `✦ OpenCode`. This uses WezTerm's
[`format-window-title` hook](https://wezterm.org/config/lua/window-events/format-window-title.html);
if you use your own config instead, include the same hook there to get live
title formatting.

See the official [WezTerm configuration files documentation](https://wezterm.org/config/files.html)
for the Lua config format.

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
"C:\Program Files\WezTerm\wezterm-gui.exe" --config-file "tunnels.lua" start --cwd . -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./TW.sh"
```

The project folder is entered only once, in **Start in**. `--cwd .` tells
WezTerm to start the initial terminal in that folder, so the relative
`tunnels.lua` and `bash ./TW.sh` paths resolve there. Adjust the WezTerm
and Git Bash paths if they are installed elsewhere. This version assumes that
`tunnels.lua` exists in the project folder. Keep the `--` before the Git Bash
executable; it separates WezTerm's options from the command to run. When your
TunnelWizard config and SSH config are in a subfolder such as `work`, use this
target instead (paths are relative to **Start in**):

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" --config-file "tunnels.lua" start --cwd . -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./TW.sh ./work/tunnels-work.conf -cssh ./work/work.ssh.conf"
```

Without a custom Lua config, use:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" start --cwd . -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./TW.sh"
```

The shortcut starts the wizard **inside WezTerm**, so saved shells use
WezTerm's new-window behavior. If you instead start the wizard in another
terminal, it uses the operating-system fallback described above.

The **Start in** field supplies the working directory, so the shortcut can
use `bash ./TW.sh` without a long path. Once started, the script locates
its default config beside itself.

To use the included Windows shortcut icon, open the shortcut's **Properties**,
choose **Change Icon**, and browse to `TunnelWizard.ico` in the project folder.

## Focused tests

Run the shell test suites from the project folder:

```bash
for test in tests/test-*.sh; do bash "$test" || exit; done
```

On Windows, run `powershell.exe -NoProfile -File tests/test-hosts-plan.ps1` for
in-memory hosts-presence and block-planning tests. These checks never edit the
real hosts file.
