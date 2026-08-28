-- Keybindings for whisper-dictate.
--
-- Installed to ~/.config/hypr/whisper_dictate.lua and loaded from
-- ~/.config/hypr/hyprland.lua via require("hypr.whisper_dictate").

local dictate = os.getenv("HOME") .. "/.local/bin/whisper-dictate"

-- Omarchy binds these same keys to Voxtype whenever the voxtype binary is
-- present. Voxtype requires AVX2, so on older CPUs it is installed but dead.
-- Release the keys before claiming them, otherwise both handlers fire.
if o.cmd_present("voxtype") then
  hl.unbind("F9")
  hl.unbind("SUPER + CTRL + X")
end

-- F9 uses the configured default language, F10 forces English. Pinning the
-- language per key avoids Whisper's auto-detection pass, which roughly
-- doubles transcription time.
o.bind("SUPER + CTRL + X", "Toggle dictation", dictate .. " toggle")

o.bind("F9", "Start dictation (push-to-talk)", dictate .. " start")
o.bind("F9", "Stop dictation (push-to-talk)", dictate .. " stop", { release = true })

o.bind("F10", "Start dictation in English (push-to-talk)", dictate .. " start en")
o.bind("F10", "Stop dictation in English (push-to-talk)", dictate .. " stop", { release = true })
