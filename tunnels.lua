local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.enable_tab_bar = false

wezterm.on('format-window-title', function(tab, pane, tabs, panes, window_config)
  local vars = pane.user_vars or {}
  return vars.SSH_WIZARD_TITLE or 'SSH TUNNEL WIZARD'
end)

return config
