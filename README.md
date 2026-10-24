# SSH Tunnel Wizard

A Bash terminal UI for starting and monitoring SSH tunnels, with saved SSH
shell connections that open in separate WezTerm windows.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- An interactive terminal
- WezTerm and its `wezterm` command-line tool to open saved shells

On Windows, the setup below uses WezTerm and Git for Windows.

## Get started

Clone the repository or download and extract its ZIP. Keep `tunnels.sh` and
`tunnels.conf.example` in the resulting project folder.

Your folder might look like this:

```text
ssh-tunnel-wizard/
├── README.md
├── tunnels.sh
├── tunnels.conf.example
├── tunnels.conf          # Your local copy; do not commit it
└── tunnels.lua           # Optional: your own WezTerm Lua config
```

From the project folder, copy the example config:

```bash
cp tunnels.conf.example tunnels.conf
```

Edit `tunnels.conf` with your own hosts, usernames, forwards, and SSH key
paths. Then launch the wizard:

```bash
bash ./tunnels.sh
```

You can use `bash ./tunnels.sh` even if a ZIP extraction did not preserve
the script's executable bit.

**The default config is `tunnels.conf` next to `tunnels.sh`.** It does not
matter which directory you launch the script from. You can also supply
another config explicitly:

```bash
bash ./tunnels.sh /path/to/another.conf
```

An explicitly supplied relative config path is interpreted relative to your
current working directory, as usual.

> **Security:** The script sources its config as Bash code. Only use a
> `tunnels.conf` you trust.

## Configuration format

Define a machine and then its tunnels:

```bash
machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
tunnel DISPLAY_NAME LOCAL_FORWARD
```

Each `tunnel` belongs to the most recently declared `machine`.

- `ALIAS`: a descriptive machine name.
- `SSH_HOST`: the SSH server hostname or address.
- `SSH_USER`: the SSH username.
- `IDENTITY_FILE`: the SSH private-key path. For example,
  `~/.ssh/id_ed25519` keeps the key outside the project folder.
- `GROUP=yes`: share one SSH process for that machine's forwards.
- `GROUP=no`: start a separate SSH process for each forward.
- `LOCAL_FORWARD`: a local forward such as
  `8080:127.0.0.1:80`.

Add saved SSH shells with:

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

The start page shows up to nine shells. The `S` menu provides access to
the full list.

## WezTerm

The wizard uses the `wezterm` command-line tool to open saved shells in new
windows. Ensure `wezterm` is available in the `PATH` seen by the Bash process
running the wizard. Tunnel management itself does not require WezTerm.

If you have a custom WezTerm Lua config, you can keep a copy in the project
folder as `tunnels.lua` and pass its path with `--config-file`, as shown below.
Alternatively, use your existing Lua config elsewhere and adjust the path,
or omit `--config-file` to use WezTerm's default configuration.

The project folder contains the wizard and its config; your SSH private
keys can remain in your normal `~/.ssh` directory.

## Windows desktop shortcut

Create a desktop shortcut and set its **Target** to the following command.
Replace `<WINDOWS_USER>` with your Windows account folder name, and adjust
the installation paths if necessary:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" --config-file "C:\Users\<WINDOWS_USER>\Projects\ssh-tunnel-wizard\tunnels.lua" start --cwd "C:\Users\<WINDOWS_USER>\Projects\ssh-tunnel-wizard" -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./tunnels.sh"
```

This example assumes that you cloned or extracted the project to
`C:\Users\<WINDOWS_USER>\Projects\ssh-tunnel-wizard`, put your personal
`tunnels.conf` there, and have a Lua config named `tunnels.lua` there.

If you do **not** have a custom Lua config, remove the `--config-file`
option and its path:

```text
"C:\Program Files\WezTerm\wezterm-gui.exe" start --cwd "C:\Users\<WINDOWS_USER>\Projects\ssh-tunnel-wizard" -- "C:\Program Files\Git\bin\bash.exe" -c "bash ./tunnels.sh"
```

The `--cwd` value makes Git Bash start in the project folder. The script
would find its config beside itself regardless, but `--cwd` lets the
shortcut use the simple `bash ./tunnels.sh` command.

If saved shells report that the WezTerm CLI cannot be found, make sure
the `wezterm` command is available in Git Bash's `PATH`.

## Repository safety

Commit `tunnels.conf.example`, not your personal `tunnels.conf`. Add this
line to a `.gitignore` in the project folder:

```gitignore
tunnels.conf
```

Do not put private SSH keys or credentials in the repository.
