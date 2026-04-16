-- bmTab.lua
-- A tab bar class with memorized reorder support via drag-and-drop and
-- right-click context menu.

local ImGui   = require('ImGui')

local BMTab   = {}
BMTab.__index = BMTab

--- @param id              string        Unique string ID for this tab bar.
--- @param labels          table         Ordered list of tab label strings.
--- @param onOrderChanged  function|nil  Called with new labels table on reorder.
---                                      Signature: fn(newLabels: string[])
--- @param onTabContext    function|nil  Called inside each tab's right-click popup
---                                      before the reorder items, for caller-injected
---                                      menu items (e.g. rename).
---                                      Signature: fn(label: string, index: number)
--- @return any
function BMTab.new(id, labels, onOrderChanged, onTabContext)
    local self          = setmetatable({}, BMTab)
    self.id             = id
    self.labels         = {}
    self.onOrderChanged = onOrderChanged
    self.onTabContext   = onTabContext
    self.selectedLabel  = nil
    self.pendingSelect  = false

    for i, v in ipairs(labels) do
        self.labels[i] = v
    end
    self.selectedLabel = self.labels[1]

    return self
end

--- Replace the full label list (e.g. after loading saved order from settings).
--- Does not fire onOrderChanged.
--- @param labels table
function BMTab:SetLabels(labels)
    self.labels = {}
    for i, v in ipairs(labels) do
        self.labels[i] = v
    end
    local stillExists = false
    for _, v in ipairs(self.labels) do
        if v == self.selectedLabel then
            stillExists = true; break
        end
    end
    if not stillExists then
        self.selectedLabel = self.labels[1]
    end
end

--- Returns a copy of the current ordered label list.
--- @return table
function BMTab:GetLabels()
    local copy = {}
    for i, v in ipairs(self.labels) do copy[i] = v end
    return copy
end

--- Returns the currently selected tab label.
--- @return string|nil
function BMTab:GetSelected()
    return self.selectedLabel
end

--- Returns the index of the currently selected tab, or nil.
--- @return number|nil
function BMTab:GetSelectedIndex()
    for i, v in ipairs(self.labels) do
        if v == self.selectedLabel then return i end
    end
    return nil
end

--- Programmatically select a tab by label.
--- @param label string
function BMTab:Select(label)
    self.selectedLabel = label
    self.pendingSelect = true
end

--- Add a new tab at the end. Fires onOrderChanged.
--- @param label string
function BMTab:AddTab(label)
    self.labels[#self.labels + 1] = label
    if self.onOrderChanged then self.onOrderChanged(self:GetLabels()) end
end

--- Remove a tab by label. Fires onOrderChanged.
--- @param label string
function BMTab:RemoveTab(label)
    for i, v in ipairs(self.labels) do
        if v == label then
            table.remove(self.labels, i)
            if self.selectedLabel == label then
                self.selectedLabel = self.labels[math.max(1, i - 1)]
            end
            if self.onOrderChanged then self.onOrderChanged(self:GetLabels()) end
            return
        end
    end
end

--- Rename a tab in the label list. Fires onOrderChanged.
--- @param oldLabel string
--- @param newLabel string
function BMTab:RenameTab(oldLabel, newLabel)
    for i, v in ipairs(self.labels) do
        if v == oldLabel then
            self.labels[i] = newLabel
            if self.selectedLabel == oldLabel then
                self.selectedLabel = newLabel
            end
            if self.onOrderChanged then self.onOrderChanged(self:GetLabels()) end
            return
        end
    end
end

-- Internal: move tab at srcIdx to dstIdx, fires onOrderChanged.
function BMTab:_move(srcIdx, dstIdx)
    if srcIdx == dstIdx or srcIdx < 1 or dstIdx < 1
        or srcIdx > #self.labels or dstIdx > #self.labels then
        return
    end
    local label = table.remove(self.labels, srcIdx)
    table.insert(self.labels, dstIdx, label)
    -- After a reorder the stable ###IDs shift, so we need SetSelected next frame.
    self.pendingSelect = true
    if self.onOrderChanged then self.onOrderChanged(self:GetLabels()) end
end

local DND_TYPE = 'BMTAB_REORDER'

function BMTab:Render()
    if not ImGui.BeginTabBar('##bmtab_' .. self.id, ImGuiTabBarFlags.FittingPolicyScroll) then
        return self.selectedLabel, self:GetSelectedIndex()
    end

    for idx, label in ipairs(self.labels) do
        local tabFlags = ImGuiTabItemFlags.None
        if self.pendingSelect and label == self.selectedLabel then
            tabFlags = bit32.bor(tabFlags, ImGuiTabItemFlags.SetSelected)
        end

        local open = ImGui.BeginTabItem(label .. '###bmtab_' .. self.id .. '_' .. idx, nil, tabFlags)
        if open then
            self.selectedLabel = label
            ImGui.EndTabItem()
        end

        -- Drag source: drag this tab by its index.
        if ImGui.BeginDragDropSource(ImGuiDragDropFlags.SourceNoPreviewTooltip) then
            ImGui.SetDragDropPayload(DND_TYPE .. self.id, idx)
            ImGui.BeginTooltip()
            ImGui.Text(label)
            ImGui.EndTooltip()
            ImGui.EndDragDropSource()
        end

        -- Drop target: accept a tab index and move it here.
        if ImGui.BeginDragDropTarget() then
            local payload = ImGui.AcceptDragDropPayload(DND_TYPE .. self.id)
            if payload then
                self:_move(payload.Data, idx)
            end
            ImGui.EndDragDropTarget()
        end

        if ImGui.BeginPopupContextItem('##bmtab_ctx_' .. self.id .. '_' .. idx) then
            if self.onTabContext then
                self.onTabContext(label, idx)
                ImGui.Separator()
            end

            ImGui.TextDisabled('Reorder')
            ImGui.BeginDisabled(idx == 1)
            if ImGui.MenuItem(Icons and (Icons.MD_KEYBOARD_ARROW_LEFT .. ' Move Left') or 'Move Left') then
                self:_move(idx, idx - 1)
            end
            ImGui.EndDisabled()

            ImGui.BeginDisabled(idx == #self.labels)
            if ImGui.MenuItem(Icons and (Icons.MD_KEYBOARD_ARROW_RIGHT .. ' Move Right') or 'Move Right') then
                self:_move(idx, idx + 1)
            end
            ImGui.EndDisabled()

            ImGui.Separator()
            ImGui.BeginDisabled(idx == 1)
            if ImGui.MenuItem('Move to First') then self:_move(idx, 1) end
            ImGui.EndDisabled()

            ImGui.BeginDisabled(idx == #self.labels)
            if ImGui.MenuItem('Move to Last') then self:_move(idx, #self.labels) end
            ImGui.EndDisabled()

            ImGui.EndPopup()
        end
    end

    self.pendingSelect = false
    ImGui.EndTabBar()
    return self.selectedLabel, self:GetSelectedIndex()
end

return BMTab
