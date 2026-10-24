# SSH Tunnel Wizard

A Bash terminal UI for starting and monitoring SSH tunnels, with saved SSH
shell connections that open in separate WezTerm windows.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- WezTerm and its `wezterm` command-line tool, for opening saved shells
- An interactive terminal

The script expects the SSH credentials and network access needed for your
configured hosts to be available.

## Setup

1. Save the script as `tunnels.sh`.
2. Make it executable:

   ```bash
   chmod +x tunnels.sh
