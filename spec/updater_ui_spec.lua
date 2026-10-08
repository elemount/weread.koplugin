package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
local shown_widget
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown_widget = widget end,
        close = function(_self, widget)
            if shown_widget == widget then shown_widget = nil end
        end,
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
        unschedule = function() end,
    }
end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_, value) return value end }
end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(value) return value end,
        T = function(template, ...)
            local values = { ... }
            return (template:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local UpdaterUI = require("weread.ui.updater")
local state = { available_version = "0.7.0" }
local settings = {
    data_dir = "/tmp",
    get = function() return state end,
    set = function(_, _, value) state = value end,
    flush = function() end,
}
local core = require("weread.lib.updater"):new{
    settings = settings, current_version = "0.6.0", plugin_dir = "/tmp/weread.koplugin",
}
local ui = UpdaterUI:new{
    updater = core,
    settings = settings,
}

expect(ui:has_update(), "UI did not delegate update state")
expect(ui:available_version() == "0.7.0",
    "UI did not delegate available version")

local download_title = ui:_progress_title{
    stage = "downloading",
    current = 512 * 1024,
    total = 1024 * 1024,
}
expect(download_title:find("50%%") ~= nil,
    "download title did not show the real percentage")
expect(download_title:find("512 KB", 1, true) ~= nil
    and download_title:find("1.0 MB", 1, true) ~= nil,
    "download title did not show transferred bytes")
expect(ui:_progress_title{ stage = "verifying" }
    == "Verifying update package…", "verification stage title was wrong")
expect(ui:_progress_title{ stage = "extracting" }
    == "Extracting update package…", "extraction stage title was wrong")
expect(ui:_progress_title{ stage = "installing" }
    == "Installing update…", "installation stage title was wrong")

ui:_show_release{
    version = "0.7.0",
    notes = "First change\nSecond change",
}
expect(shown_widget.title == "New version available\nWeRead v0.6.0 → v0.7.0",
    "release notes viewer title was wrong")
expect(shown_widget.text == "First change\nSecond change"
    and shown_widget.buttons_table[1][1].text == "Close"
    and shown_widget.buttons_table[2][1].text == "Update now",
    "release notes viewer did not expose notes and install action")
expect(shown_widget.add_default_buttons == false and shown_widget.show_menu == false,
    "release viewer must not add navigation buttons")
shown_widget.buttons_table[1][1].callback()
expect(shown_widget == nil, "close button did not dismiss the release notes")

local fetched = { version = "0.7.0", notes = "Release notes" }
local fetch_modes = {}
core.fetch_release = function(_self, use_proxy)
    fetch_modes[#fetch_modes + 1] = use_proxy
    return fetched
end
ui._run_subprocess = function(_self, message, task, callback)
    callback(task())
end
ui:check(false)
expect(shown_widget and shown_widget.text == fetched.notes
    and fetch_modes[#fetch_modes] == false,
    "manual direct check did not show the release")
local release_viewer = shown_widget
local another_ui = UpdaterUI:new{ updater = core, settings = settings }
expect(another_ui:_show_release(fetched) == nil and shown_widget == release_viewer,
    "two plugin instances displayed duplicate update dialogs")
release_viewer.close_callback()
shown_widget = nil
fetched = { version = "0.8.0", notes = "Newer notes" }
ui:check(true)
expect(shown_widget and shown_widget.text == "Newer notes"
    and fetch_modes[#fetch_modes] == true,
    "manual proxy check did not show the release")
shown_widget.close_callback()
shown_widget = nil
fetched = { version = "0.6.0" }
ui:check(false)
expect(shown_widget and shown_widget.text == "WeRead Plugin is up to date (v0.6.0).",
    "manual check should report that the plugin is current")
shown_widget = nil
fetched = nil
ui:check(false)
expect(shown_widget and shown_widget.text:find("Update check failed", 1, true),
    "manual failure should still be reported")
shown_widget = nil

local installed
ui.install = function(_self, value) installed = value end
local install_release = { version = "0.9.0", notes = "Install now" }
ui:_show_release(install_release)
local install_button = shown_widget.buttons_table[2][1]
install_button.callback()
expect(shown_widget and shown_widget.title:find("Choose how to connect", 1, true),
    "install button must ask for a connection choice")
expect(another_ui:_show_release(install_release) == nil, "install must suppress concurrent dialogs")
shown_widget.buttons[1][1].callback()
scheduled[#scheduled].callback()
expect(installed == install_release, "install button did not use the displayed release")
local scheduled_count = #scheduled
install_button.callback()
expect(#scheduled == scheduled_count, "double activation scheduled two installs")

print(("updater_ui_spec: %d checks"):format(checks))
