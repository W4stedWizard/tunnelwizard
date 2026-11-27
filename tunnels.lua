local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.enable_tab_bar = false

local star_prefix = '✦ '
local dashboard_title_prefix = 'TW✦ '

local function wizard_window_title(pane)
  local vars = pane.user_vars or {}
  local launch_title = vars.SSH_WIZARD_TITLE
  if not launch_title then
    return 'TW✦ TunnelWizard'
  end

  -- Keep the dashboard's own title, but let app-reported OSC titles update
  -- TunnelWizard-launched shells while retaining the brand prefix.
  if launch_title:sub(1, #dashboard_title_prefix) == dashboard_title_prefix then
    return launch_title
  end

  local title = pane.title or ''
  local lower_title = title:lower()
  if title == '' or lower_title == 'wezterm' or lower_title == 'bash' or
      lower_title == 'ssh' then
    title = launch_title
  end
  if title:sub(1, #star_prefix) ~= star_prefix then
    title = star_prefix .. title
  end
  return title
end

wezterm.on('format-window-title', function(tab, pane, tabs, panes, window_config)
  return wizard_window_title(pane)
end)

return config
