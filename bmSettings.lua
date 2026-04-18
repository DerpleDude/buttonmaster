local mq               = require('mq')
local PackageMan       = require('mq.PackageMan')
local SQLite3          = PackageMan.Require('lsqlite3')
local btnUtils         = require('lib.buttonUtils')
local BMButtonHandlers = require('bmButtonHandlers')

local settings_base    = mq.configDir .. '/ButtonMaster'
local settings_path    = settings_base .. '.lua'
local dbPath           = settings_base .. '.db'


local BMSettings                 = {}
BMSettings.__index               = BMSettings
BMSettings.settings              = {}
BMSettings.CharConfig            = string.format("%s_%s", mq.TLO.EverQuest.Server(), mq.TLO.Me.DisplayName())
BMSettings.Constants             = {}

BMSettings.Globals               = {}
BMSettings.Globals.Version       = 8
BMSettings.Globals.CustomThemes  = {}

BMSettings.Constants.TimerTypes  = {
    "Seconds Timer",
    "Item",
    "Spell Gem",
    "AA",
    "Ability",
    "Disc",
    "Custom Lua",
}

BMSettings.Constants.UpdateRates = {
    { Display = "Unlimited",     Value = 0, },
    { Display = "1 per second",  Value = 1, },
    { Display = "2 per second",  Value = 0.5, },
    { Display = "4 per second",  Value = 0.25, },
    { Display = "10 per second", Value = 0.1, },
    { Display = "20 per second", Value = 0.05, },
}


function BMSettings:OpenDB()
    local db = SQLite3.open(dbPath)
    if not db then
        btnUtils.Output('\arFailed to open ButtonMaster database!')
        return nil
    end
    db:busy_timeout(2000)
    db:exec('PRAGMA journal_mode=WAL;')
    db:exec('PRAGMA foreign_keys = ON;')
    return db
end

function BMSettings:InitDB()
    local db = self:OpenDB()
    if not db then return false end

    db:exec([[
        CREATE TABLE IF NOT EXISTS metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS buttons (
            button_key     TEXT PRIMARY KEY,
            label          TEXT NOT NULL DEFAULT '',
            cmd            TEXT NOT NULL DEFAULT '',
            icon           TEXT,
            icon_type      TEXT,
            icon_lua       TEXT,
            cooldown       TEXT,
            timer_type     TEXT,
            timer          TEXT,
            toggle_check   TEXT,
            button_color   TEXT,
            text_color     TEXT,
            show_label     INTEGER DEFAULT 1,
            evaluate_label INTEGER DEFAULT 0,
            update_rate    REAL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS sets (
            set_name   TEXT NOT NULL,
            position   INTEGER NOT NULL,
            button_key TEXT NOT NULL,
            PRIMARY KEY (set_name, position)
        );

        CREATE TABLE IF NOT EXISTS windows (
            character_key  TEXT NOT NULL,
            window_id      INTEGER NOT NULL,
            visible        INTEGER NOT NULL DEFAULT 1,
            locked         INTEGER NOT NULL DEFAULT 0,
            hide_titlebar  INTEGER NOT NULL DEFAULT 0,
            compact_mode   INTEGER NOT NULL DEFAULT 0,
            adv_tooltips   INTEGER NOT NULL DEFAULT 1,
            show_search    INTEGER NOT NULL DEFAULT 0,
            per_char_pos   INTEGER NOT NULL DEFAULT 0,
            hide_scrollbar INTEGER NOT NULL DEFAULT 0,
            theme          TEXT,
            font           INTEGER NOT NULL DEFAULT 10,
            button_size    INTEGER NOT NULL DEFAULT 6,
            fps            REAL NOT NULL DEFAULT 0,
            pos_x          REAL NOT NULL DEFAULT 10,
            pos_y          REAL NOT NULL DEFAULT 10,
            width          REAL NOT NULL DEFAULT 500,
            height         REAL NOT NULL DEFAULT 300,
            PRIMARY KEY (character_key, window_id)
        );

        CREATE TABLE IF NOT EXISTS window_sets (
            character_key TEXT NOT NULL,
            window_id     INTEGER NOT NULL,
            position      INTEGER NOT NULL,
            set_name      TEXT NOT NULL,
            PRIMARY KEY (character_key, window_id, position),
            FOREIGN KEY (character_key, window_id)
                REFERENCES windows(character_key, window_id) ON DELETE CASCADE
        );
    ]])

    db:exec('PRAGMA wal_checkpoint(TRUNCATE);')
    db:close()
    return true
end

function BMSettings:execDB(db, query, ...)
    local stmt = db:prepare(query)
    if not stmt then
        btnUtils.Output('\arDB prepare error: %s\nQuery: %s', db:errmsg(), query)
        return false
    end
    if select('#', ...) > 0 then
        stmt:bind_values(...)
    end
    local rc = stmt:step()
    stmt:finalize()
    return rc
end

function BMSettings:queryDB(db, query, ...)
    local stmt = db:prepare(query)
    if not stmt then
        btnUtils.Output('\arDB query error: %s', db:errmsg())
        return {}
    end
    if select('#', ...) > 0 then
        stmt:bind_values(...)
    end
    local rows = {}
    for row in stmt:nrows() do
        table.insert(rows, row)
    end
    stmt:finalize()
    return rows
end

function BMSettings.new()
    local newSettings      = setmetatable({}, BMSettings)
    newSettings.CharConfig = string.format("%s_%s", mq.TLO.EverQuest.Server(), mq.TLO.Me.DisplayName())


    local config, err = loadfile(mq.configDir .. '/Button_Master_Theme.lua')
    if not err and config then
        BMSettings.Globals.CustomThemes = config()
    end

    return newSettings
end

function BMSettings:SaveSettings(doBroadcast)
    if doBroadcast == nil then doBroadcast = true end

    -- Daily backup (pickle to backups folder as safety net)
    if not self.settings.LastBackup or os.time() - self.settings.LastBackup > 3600 * 24 then
        self.settings.LastBackup = os.time()
        mq.pickle(mq.configDir .. "/Buttonmaster-Backups/ButtonMaster-backup-" .. os.date("%m-%d-%y-%H-%M-%S") .. ".lua",
            self.settings)
    end

    -- Write to SQLite instead of pickle
    self:writeAllToDB()

    -- Inform others of changes so they can load them from the db
    if doBroadcast and mq.TLO.MacroQuest.GameState() == "INGAME" then
        btnUtils.Output("\aySent Event from(\am%s\ay) event(\at%s\ay)", mq.TLO.Me.DisplayName(), "SettingsChanged")
        ButtonActors.send({
            from = mq.TLO.Me.DisplayName(),
            script = "ButtonMaster",
            event = "SettingsChanged",
        })
    end
end

function BMSettings:NeedUpgrade()
    return (self.settings.Version or 0) < BMSettings.Globals.Version
end

function BMSettings:GetSettings()
    return self.settings
end

function BMSettings:GetSetting(settingKey)
    -- main setting
    if self.settings.Global[settingKey] ~= nil then return self.settings.Global[settingKey] end

    -- character sertting
    if self.settings.Characters[self.CharConfig] ~= nil and self.settings.Characters[self.CharConfig][settingKey] ~= nil then
        return self.settings.Characters[self.CharConfig]
            [settingKey]
    end

    -- not found.
    btnUtils.Debug("Setting not Found: %s", settingKey)
end

function BMSettings:GetCharacterWindow(windowId)
    return self.settings.Characters[self.CharConfig].Windows[windowId]
end

function BMSettings:GetCharacterWindowSets(windowId)
    if not self.settings.Characters or
        not self.settings.Characters[self.CharConfig] or
        not self.settings.Characters[self.CharConfig].Windows or
        not self.settings.Characters[self.CharConfig].Windows[windowId] or
        not self.settings.Characters[self.CharConfig].Windows[windowId].Sets then
        return {}
    end

    return self.settings.Characters[self.CharConfig].Windows[windowId].Sets
end

function BMSettings:GetCharConfig()
    return self.settings.Characters[self.CharConfig]
end

function BMSettings:GetButtonSectionKeyBySetIndex(Set, Index)
    -- an invalid set exists. Just make it empty.
    if not self.settings.Sets[Set] then
        self.settings.Sets[Set] = {}
        btnUtils.Debug("Set: %s does not exist. Creating it.", Set)
    end

    local key = self.settings.Sets[Set][Index]

    -- if the key doesn't exist, get the current button counter and add 1
    if key == nil then
        key = self:GenerateButtonKey()
    end
    return key
end

function BMSettings:GetNextWindowId()
    return #self:GetCharConfig().Windows + 1
end

function BMSettings:GenerateButtonKey()
    local i = 1
    while (true) do
        local buttonKey = string.format("Button_%d", i)
        if self.settings.Buttons[buttonKey] == nil then
            return buttonKey
        end
        i = i + 1
    end
end

function BMSettings:ImportButtonAndSave(button, save)
    local key = self:GenerateButtonKey()
    self.settings.Buttons[key] = button
    btnUtils.Output("\agImported Button: \at%s\ag as \at%s", BMButtonHandlers.ResolveButtonLabel(button, true) or "<No Label>", key)
    if save then
        self:SaveSettings(true)
    end
    return key
end

---comment
---@param Set string
---@param Index number
---@return table
function BMSettings:GetButtonBySetIndex(Set, Index)
    if self.settings.Sets[Set] and self.settings.Sets[Set][Index] and self.settings.Buttons[self.settings.Sets[Set][Index]] then
        return self.settings.Buttons[self.settings.Sets[Set][Index]]
    end

    return { Unassigned = true, Label = tostring(Index), }
end

function BMSettings:ImportSetAndSave(sharableSet, windowId)
    -- is setname unqiue?
    local setName = sharableSet.Key
    if self.settings.Sets[setName] ~= nil then
        local newSetName = setName .. "_Imported_" .. os.date("%m-%d-%y-%H-%M-%S")
        btnUtils.Output("\ayImport Set Warning: Set name: \at%s\ay already exists renaming it to \at%s\ax", setName,
            newSetName)
        setName = newSetName
    end

    btnUtils.Output("\agImporting Set: \at%s\ag with \at%d\ag buttons", setName, #(sharableSet.Set or {}))

    self.settings.Sets[setName] = {}
    for index, btnName in pairs(sharableSet.Set or {}) do
        local newButtonName = self:ImportButtonAndSave(sharableSet.Buttons[btnName], false)
        self.settings.Sets[setName][index] = newButtonName
    end

    -- add set to user
    table.insert(self.settings.Characters[self.CharConfig].Windows[windowId].Sets, setName)

    self:SaveSettings(true)
end

function BMSettings:ConvertToLatestConfigVersion()
    -- Load from the old .lua file directly (avoid LoadSettings which would trigger DB migration)
    if not self.settings or not next(self.settings) then
        local config, err = loadfile(settings_path)
        if not err and config then
            self.settings = config()
        else
            btnUtils.Output('\arNo config to upgrade!')
            return
        end
    end
    local needsSave = false
    local newSettings = {}

    if not self.settings.Version then
        -- version 2
        -- Run through all settings and make sure they are in the new format.
        for key, value in pairs(self.settings or {}) do
            -- TODO: Make buttons a seperate table instead of doing the string compare crap.
            if type(value) == 'table' then
                if key:find("^(Button_)") and value.Cmd1 or value.Cmd2 or value.Cmd3 or value.Cmd4 or value.Cmd5 then
                    btnUtils.Output("Key: %s Needs Converted!", key)
                    value.Cmd  = string.format("%s\n%s\n%s\n%s\n%s\n%s", value.Cmd or '', value.Cmd1 or '',
                        value.Cmd2 or '',
                        value.Cmd3 or '', value.Cmd4 or '', value.Cmd5 or '')
                    value.Cmd  = value.Cmd:gsub("\n+", "\n")
                    value.Cmd  = value.Cmd:gsub("\n$", "")
                    value.Cmd  = value.Cmd:gsub("^\n", "")
                    value.Cmd1 = nil
                    value.Cmd2 = nil
                    value.Cmd3 = nil
                    value.Cmd4 = nil
                    value.Cmd5 = nil
                    needsSave  = true
                    btnUtils.Output("\atUpgraded to \amv2\at!")
                end
            end
        end

        -- version 3
        -- Okay now that a similar but lua-based config is stabalized the next pass is going to be
        -- cleaning up the data model so we aren't doing a ton of string compares all over.
        newSettings.Buttons = {}
        newSettings.Sets = {}
        newSettings.Characters = {}
        newSettings.Global = self.settings.Global
        for key, value in pairs(self.settings) do
            local sStart, sEnd = key:find("^Button_")
            if sStart then
                local newKey = key --key:sub(sEnd + 1)
                btnUtils.Output("Old Key: \am%s\ax, New Key: \at%s\ax", key, newKey)
                newSettings.Buttons[newKey] = newSettings.Buttons[newKey] or {}
                if type(value) == 'table' then
                    for subKey, subValue in pairs(value) do
                        newSettings.Buttons[newKey][subKey] = tostring(subValue)
                    end
                end
                needsSave = true
            end
            sStart, sEnd = key:find("^Set_")
            if sStart then
                local newKey = key:sub(sEnd + 1)
                btnUtils.Output("Old Key: \am%s\ax, New Key: \at%s\ax", key, newKey)
                newSettings.Sets[newKey] = value
                needsSave                = true
            end
            sStart, sEnd = key:find("^Char_(.*)_Config")
            if sStart then
                local newKey = key:sub(sStart + 5, sEnd - 7)
                btnUtils.Output("Old Key: \am%s\ax, New Key: \at%s\ax", key, newKey)
                newSettings.Characters[newKey] = newSettings.Characters[newKey] or {}
                if type(value) == 'table' then
                    for subKey, subValue in pairs(value) do
                        newSettings.Characters[newKey].Sets = newSettings.Characters[newKey].Sets or {}
                        if type(subKey) == "number" then
                            table.insert(newSettings.Characters[newKey].Sets, subValue)
                        else
                            newSettings.Characters[newKey][subKey] = subValue
                        end
                    end
                end

                needsSave = true
            end
        end

        if needsSave then
            -- be nice and make a backup.
            mq.pickle(mq.configDir .. "/ButtonMaster-v3-" .. os.date("%m-%d-%y-%H-%M-%S") .. ".lua", self.settings)
            self.settings = newSettings
            self:SaveSettings(true)
            needsSave = false
            btnUtils.Output("\atUpgraded to \amv3\at!")
        end
    end

    -- version 4 same as 5 but moved the version data around
    -- version 5
    -- Move Character sets to a specific window name
    if (self.settings.Version or 0) < 5 then
        mq.pickle(mq.configDir .. "/ButtonMaster-v4-" .. os.date("%m-%d-%y-%H-%M-%S") .. ".lua", self.settings)

        needsSave = true
        newSettings = self.settings
        newSettings.Version = 5
        for charKey, _ in pairs(self.settings.Characters or {}) do
            if self.settings.Characters[charKey] and self.settings.Characters[charKey].Sets ~= nil then
                newSettings.Characters[charKey].Windows = {}
                table.insert(newSettings.Characters[charKey].Windows,
                    { Sets = newSettings.Characters[charKey].Sets, Visible = true, })
                newSettings.Characters[charKey].Sets = nil
                needsSave = true
            end
        end
        if needsSave then
            self.settings = newSettings
            self:SaveSettings(true)
            btnUtils.Output("\atUpgraded to \amv5\at!")
        end
    end

    -- version 6
    -- Moved TitleBar/Locked into the window settings
    -- Removed Button Count
    -- Removed Defaults for now
    if (self.settings.Version or 0) < 6 then
        mq.pickle(mq.configDir .. "/ButtonMaster-v5-" .. os.date("%m-%d-%y-%H-%M-%S") .. ".lua", self.settings)
        needsSave = true
        newSettings = self.settings
        newSettings.Version = 6
        newSettings.Defaults = nil

        for _, curCharData in pairs(newSettings.Characters or {}) do
            for _, windowData in ipairs(curCharData.Windows or {}) do
                windowData.Locked = curCharData.Locked or false
                windowData.HideTitleBar = curCharData.HideTitleBar or false
            end
            curCharData.HideTitleBar = nil
            curCharData.Locked = nil
        end

        newSettings.Global.ButtonCount = nil

        if needsSave then
            self.settings = newSettings
            self:SaveSettings(true)
            btnUtils.Output("\atUpgraded to \amv6\at!")
        end
    end

    -- version 7
    -- moved ButtonSize and Font to each hotbar
    if (self.settings.Version or 0) < 7 then
        mq.pickle(mq.configDir .. "/ButtonMaster-v6-" .. os.date("%m-%d-%y-%H-%M-%S") .. ".lua", self.settings)
        needsSave = true
        newSettings = self.settings
        newSettings.Version = 7

        for _, curCharData in pairs(newSettings.Characters or {}) do
            for _, windowData in ipairs(curCharData.Windows or {}) do
                windowData.Font = (newSettings.Global.Font or 1) * 10
                windowData.ButtonSize = newSettings.Global.ButtnSize or 6
            end
        end

        newSettings.Global.Font = nil
        newSettings.Global.ButtonSize = nil
        newSettings.Global = nil

        if needsSave then
            self.settings = newSettings
            self:SaveSettings(true)
            btnUtils.Output("\atUpgraded to \amv%d\at!", BMSettings.Globals.Version)
        end
    end
end

function BMSettings:InvalidateButtonCache()
    for _, button in pairs(self.settings.Buttons or {}) do
        button.CachedLabel = nil
    end
end

function BMSettings:writeAllToDB()
    local db = self:OpenDB()
    if not db then return false end

    local ok, err = pcall(function()
        db:exec('BEGIN TRANSACTION')

        -- Clear all tables note:order matters for foreign keys
        db:exec('DELETE FROM window_sets')
        db:exec('DELETE FROM windows')
        db:exec('DELETE FROM sets')
        db:exec('DELETE FROM buttons')

        -- Write buttons
        local btnStmt = db:prepare([[
            INSERT INTO buttons (button_key, label, cmd, icon, icon_type, icon_lua,
                cooldown, timer_type, timer, toggle_check, button_color, text_color,
                show_label, evaluate_label, update_rate)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not btnStmt then error('Failed to prepare buttons insert: ' .. (db:errmsg() or 'unknown')) end
        for key, btn in pairs(self.settings.Buttons or {}) do
            if not btn.Unassigned then
                btnStmt:bind_values(
                    key,
                    btn.Label or '',
                    btn.Cmd or '',
                    btn.Icon and tostring(btn.Icon) or nil,
                    btn.IconType,
                    btn.IconLua,
                    btn.Cooldown and tostring(btn.Cooldown) or nil,
                    btn.TimerType,
                    btn.Timer,
                    btn.ToggleCheck,
                    btn.ButtonColorRGB,
                    btn.TextColorRGB,
                    (btn.ShowLabel == nil or btn.ShowLabel) and 1 or 0,
                    btn.EvaluateLabel and 1 or 0,
                    btn.UpdateRate or 0
                )
                btnStmt:step()
                btnStmt:reset()
            end
        end
        btnStmt:finalize()

        -- Write sets
        local setStmt = db:prepare('INSERT INTO sets (set_name, position, button_key) VALUES (?, ?, ?)')
        if not setStmt then error('Failed to prepare sets insert: ' .. (db:errmsg() or 'unknown')) end
        for setName, buttons in pairs(self.settings.Sets or {}) do
            for pos, buttonKey in pairs(buttons) do
                setStmt:bind_values(setName, pos, buttonKey)
                setStmt:step()
                setStmt:reset()
            end
        end
        setStmt:finalize()

        -- Write windows and window_sets
        local winStmt = db:prepare([[
            INSERT INTO windows (character_key, window_id, visible, locked, hide_titlebar,
                compact_mode, adv_tooltips, show_search, per_char_pos, hide_scrollbar,
                theme, font, button_size, fps, pos_x, pos_y, width, height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not winStmt then error('Failed to prepare windows insert: ' .. (db:errmsg() or 'unknown')) end
        local wsStmt = db:prepare('INSERT INTO window_sets (character_key, window_id, position, set_name) VALUES (?, ?, ?, ?)')
        if not wsStmt then error('Failed to prepare window_sets insert: ' .. (db:errmsg() or 'unknown')) end

        for charKey, charData in pairs(self.settings.Characters or {}) do
            for winId, win in ipairs(charData.Windows or {}) do
                winStmt:bind_values(
                    charKey, winId,
                    win.Visible and 1 or 0,
                    win.Locked and 1 or 0,
                    win.HideTitleBar and 1 or 0,
                    win.CompactMode and 1 or 0,
                    (win.AdvTooltips == nil or win.AdvTooltips) and 1 or 0,
                    win.ShowSearch and 1 or 0,
                    win.PerCharacterPositioning and 1 or 0,
                    win.HideScrollbar and 1 or 0,
                    win.Theme,
                    win.Font or 10,
                    win.ButtonSize or 6,
                    win.FPS or 0,
                    win.Pos and win.Pos.x or 10,
                    win.Pos and win.Pos.y or 10,
                    win.Width or 500,
                    win.Height or 300
                )
                winStmt:step()
                winStmt:reset()

                for pos, setName in ipairs(win.Sets or {}) do
                    wsStmt:bind_values(charKey, winId, pos, setName)
                    wsStmt:step()
                    wsStmt:reset()
                end
            end
        end
        winStmt:finalize()
        wsStmt:finalize()

        -- Update metadata
        self:execDB(db, 'INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)',
            'schema_version', tostring(BMSettings.Globals.Version))
        self:execDB(db, 'INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)',
            'last_backup', tostring(self.settings.LastBackup or 0))

        db:exec('COMMIT')
    end)

    if not ok then
        btnUtils.Output('\arDB write error: %s', tostring(err))
        db:exec('ROLLBACK')
        db:close()
        return false
    end

    db:close()
    return true
end

function BMSettings:retrieveDataFromDB()
    local db = self:OpenDB()
    if not db then return false end

    local settings = {
        Version = BMSettings.Globals.Version,
        Buttons = {},
        Sets = {},
        Characters = {},
    }

    -- Load metadata
    local metaRows = self:queryDB(db, 'SELECT key, value FROM metadata')
    for _, row in ipairs(metaRows) do
        if row.key == 'schema_version' then
            settings.Version = tonumber(row.value) or BMSettings.Globals.Version
        elseif row.key == 'last_backup' then
            settings.LastBackup = tonumber(row.value) or 0
        end
    end

    -- Load buttons
    local btnRows = self:queryDB(db, 'SELECT * FROM buttons')
    for _, row in ipairs(btnRows) do
        settings.Buttons[row.button_key] = {
            Label = row.label or '',
            Cmd = row.cmd or '',
            Icon = row.icon,
            IconType = row.icon_type,
            IconLua = row.icon_lua,
            Cooldown = row.cooldown,
            TimerType = row.timer_type,
            Timer = row.timer,
            ToggleCheck = row.toggle_check,
            ButtonColorRGB = row.button_color,
            TextColorRGB = row.text_color,
            ShowLabel = row.show_label == 1,
            EvaluateLabel = row.evaluate_label == 1,
            UpdateRate = row.update_rate or 0,
        }
    end

    -- Load sets
    local setRows = self:queryDB(db, 'SELECT set_name, position, button_key FROM sets ORDER BY set_name, position')
    for _, row in ipairs(setRows) do
        settings.Sets[row.set_name] = settings.Sets[row.set_name] or {}
        settings.Sets[row.set_name][row.position] = row.button_key
    end

    -- Load windows
    local winRows = self:queryDB(db, 'SELECT * FROM windows ORDER BY character_key, window_id')
    for _, row in ipairs(winRows) do
        settings.Characters[row.character_key] = settings.Characters[row.character_key] or { Windows = {}, }
        settings.Characters[row.character_key].Windows[row.window_id] = {
            Visible = row.visible == 1,
            Locked = row.locked == 1,
            HideTitleBar = row.hide_titlebar == 1,
            CompactMode = row.compact_mode == 1,
            AdvTooltips = row.adv_tooltips == 1,
            ShowSearch = row.show_search == 1,
            PerCharacterPositioning = row.per_char_pos == 1,
            HideScrollbar = row.hide_scrollbar == 1,
            Theme = row.theme,
            Font = row.font or 10,
            ButtonSize = row.button_size or 6,
            FPS = row.fps or 0,
            Pos = { x = row.pos_x or 10, y = row.pos_y or 10, },
            Width = row.width or 500,
            Height = row.height or 300,
            Sets = {},
        }
    end

    -- Load window_sets
    local wsRows = self:queryDB(db, 'SELECT * FROM window_sets ORDER BY character_key, window_id, position')
    for _, row in ipairs(wsRows) do
        if settings.Characters[row.character_key] and
            settings.Characters[row.character_key].Windows[row.window_id] then
            settings.Characters[row.character_key].Windows[row.window_id].Sets[row.position] = row.set_name
        end
    end

    db:close()
    self.settings = settings
    return true
end

function BMSettings:migrateToDatabase()
    btnUtils.Output('\ayMigrating ButtonMaster config to SQLite database...')
    if not self:InitDB() then return false end
    if not self:writeAllToDB() then return false end

    -- Rename old file as backup
    if btnUtils.file_exists(settings_path) then
        os.rename(settings_path, settings_path .. '.bak')
        btnUtils.Output('\agRenamed old config to %s.bak', settings_path)
    end

    btnUtils.Output('\agButtonMaster config migrated to SQLite successfully!')
    return true
end

function BMSettings:HasDBData()
    -- Check file exists first to avoid creating an empty .db file
    local f = io.open(dbPath, 'r')
    if not f then return false end
    f:close()
    local db = self:OpenDB()
    if not db then return false end
    local rows = self:queryDB(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='buttons'")
    db:close()
    return #rows > 0
end

function BMSettings:LoadSettings()
    -- DB first: if database exists, load from it
    if self:HasDBData() then
        self:InitDB()
        self:retrieveDataFromDB()
        goto settings_loaded
    end

    -- Fallback: try to load old .lua config and migrate
    do
        local config, err = loadfile(settings_path)
        if not err and config then
            self.settings = config()

            -- Run version upgrades if needed (v2 through v7)
            if (self.settings.Version or 0) < 7 then
                self:ConvertToLatestConfigVersion()
            end

            -- Migrate to SQLite
            self.settings.Version = BMSettings.Globals.Version
            self:migrateToDatabase()
            goto settings_loaded
        end

        -- Try legacy .ini format
        local old_settings_path = settings_path:gsub(".lua", ".ini")
        if btnUtils.file_exists(old_settings_path) then
            printf("\ayLoading legacy ini config and migrating to SQLite...")
            self.settings = btnUtils.loadINI(old_settings_path)
            self.settings.Version = BMSettings.Globals.Version
            self:migrateToDatabase()
            goto settings_loaded
        end

        -- Fresh install - create defaults
        printf("\ayNo existing config found, creating fresh ButtonMaster database.")
        self.settings = {
            Version = BMSettings.Globals.Version,
            Sets = {
                ['Primary'] = { 'Button_1', 'Button_2', 'Button_3', },
                ['Movement'] = { 'Button_4', },
            },
            Buttons = {
                Button_1 = {
                    Label = 'Burn (all)',
                    Cmd = '/bcaa //burn\n/timed 500 /bcaa //burn',
                },
                Button_2 = {
                    Label = 'Pause (all)',
                    Cmd = '/bcaa //multi ; /twist off ; /mqp on',
                },
                Button_3 = {
                    Label = 'Unpause (all)',
                    Cmd = '/bcaa //mqp off',
                },
                Button_4 = {
                    Label = 'Nav Target (bca)',
                    Cmd = '/bca //nav id ${Target.ID}',
                },
            },
            Characters = {
                [self.CharConfig] = {
                    Windows = { [1] = { Visible = true, Pos = { x = 10, y = 10, }, Sets = {}, Locked = false, }, },
                },
            },
        }
        self:InitDB()
        self:writeAllToDB()
    end

    ::settings_loaded::

    -- Ensure this character has a config entry with at least one window
    self.settings.Characters[self.CharConfig] = self.settings.Characters[self.CharConfig] or {}
    self.settings.Characters[self.CharConfig].Windows = self.settings.Characters[self.CharConfig].Windows or
        { [1] = { Visible = true, Pos = { x = 10, y = 10, }, Sets = {}, Locked = false, }, }

    self:InvalidateButtonCache()
    return true
end

return BMSettings
