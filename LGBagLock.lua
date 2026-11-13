-- LG Bag Lock
-- Copyright (C) 2026 lingeriegoat
-- This program is free software; you can redistribute it and/or modify it under
-- the terms of the GNU General Public License version 2 as published by the
-- Free Software Foundation. This program is distributed in the hope that it
-- will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
-- of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
-- Public License for more details.

local ADDON = ...
local C = C_Container
local getInfo = C.GetContainerItemInfo
local itemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local itemFamily = C_Item and C_Item.GetItemFamily or GetItemFamily
local FLAGS = Enum.BagSlotFlags
local REAGENT_BAG = Enum.BagIndex and Enum.BagIndex.ReagentBag
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local LOCKED_ICON = "Interface\\Buttons\\LockButton-Locked-Up"
local UNLOCKED_ICON = "Interface\\Buttons\\LockButton-Unlocked-Up"
local HEARTHSTONE = 6948
local DRINK_SPELL = 430
local itemSpell = C_Item and C_Item.GetItemSpell or GetItemSpell
local drinkCache = {}

local function isDrink(id)
	if drinkCache[id] == nil then
		local name = itemSpell(id)
		local drink = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(DRINK_SPELL) or GetSpellInfo(DRINK_SPELL)
		if not name or not drink then return false end
		drinkCache[id] = name == drink
	end
	return drinkCache[id]
end

local function setIcon(button, on)
	button:SetNormalTexture(on and LOCKED_ICON or UNLOCKED_ICON)
	button:GetNormalTexture():SetTexCoord(0.2, 0.8, 0.2, 0.8)
end

local FILTERS = {}
if FLAGS then
	local defs = {
		ClassEquipment = function(it) return it.class == 2 or it.class == 4 end,
		ClassConsumables = function(it) return it.class == 0 end,
		ClassProfessionGoods = function(it) return it.class == 7 end,
		ClassJunk = function(it) return it.quality == 0 end,
		ClassQuestItems = function(it) return it.class == 12 end,
	}
	for name, fn in pairs(defs) do
		if FLAGS[name] then FILTERS[FLAGS[name]] = fn end
	end
end

local db, lockMode, ready
local lockAt = {}
local lockButton

local function key(bag, slot)
	return bag * 100 + slot
end

local function rebuildIndex()
	wipe(lockAt)
	for _, e in ipairs(db.locks) do
		lockAt[key(e.b, e.s)] = e
	end
end

local function slotItemID(bag, slot)
	local info = getInfo(bag, slot)
	return info and info.itemID
end

local function reconcile()
	if not db or CursorHasItem() then return end
	local claimed, kept, pending = {}, {}, {}
	for _, e in ipairs(db.locks) do
		local k = key(e.b, e.s)
		if slotItemID(e.b, e.s) == e.i and not claimed[k] then
			claimed[k] = true
			kept[#kept + 1] = e
		else
			pending[#pending + 1] = e
		end
	end
	for _, e in ipairs(pending) do
		local fb, fs
		for b = 0, LAST_BAG do
			for s = 1, C.GetContainerNumSlots(b) do
				if not fb and not claimed[key(b, s)] and slotItemID(b, s) == e.i then
					fb, fs = b, s
				end
			end
		end
		if fb then
			e.b, e.s = fb, fs
			claimed[key(fb, fs)] = true
			kept[#kept + 1] = e
		elseif not ready then
			kept[#kept + 1] = e
		end
	end
	db.locks = kept
	rebuildIndex()
end

local function bagFrames()
	local list = { ContainerFrameCombinedBags }
	for i = 1, 13 do
		local f = _G["ContainerFrame" .. i]
		if f then list[#list + 1] = f end
	end
	return list
end

local function itemButtons(frame)
	local list = {}
	if frame.EnumerateValidItems then
		for _, b in frame:EnumerateValidItems() do list[#list + 1] = b end
	elseif frame.Items then
		for _, b in ipairs(frame.Items) do list[#list + 1] = b end
	end
	return list
end

local refresh, fitSearch, setMode

local function toggleLock(bag, slot)
	local existing = lockAt[key(bag, slot)]
	if existing then
		for i, e in ipairs(db.locks) do
			if e == existing then table.remove(db.locks, i) break end
		end
	else
		local id = slotItemID(bag, slot)
		if not id then return end
		db.locks[#db.locks + 1] = { b = bag, s = slot, i = id }
	end
	rebuildIndex()
	refresh()
end

local function decorate(btn)
	local d = {}
	d.glow = btn:CreateTexture(nil, "OVERLAY", nil, 7)
	d.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	d.glow:SetBlendMode("ADD")
	d.glow:SetVertexColor(0.25, 0.6, 1)
	d.glow:SetPoint("CENTER")
	d.glow:Hide()
	d.catcher = CreateFrame("Button", nil, btn)
	d.catcher:SetAllPoints()
	d.catcher:SetFrameLevel(btn:GetFrameLevel() + 10)
	d.catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	d.catcher:Hide()
	d.catcher:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			setMode(false)
		else
			toggleLock(btn:GetBagID(), btn:GetID())
		end
	end)
	d.catcher:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetBagItem(btn:GetBagID(), btn:GetID())
		GameTooltip:Show()
	end)
	d.catcher:SetScript("OnLeave", GameTooltip_Hide)
	btn.LGBagLock = d
	return d
end

local function paint(btn)
	local bag = btn.GetBagID and btn:GetBagID()
	if not bag then return end
	local d = btn.LGBagLock or decorate(btn)
	if lockAt[key(bag, btn:GetID())] then
		d.glow:SetSize(btn:GetWidth() * 1.75, btn:GetHeight() * 1.75)
		d.glow:Show()
	else
		d.glow:Hide()
	end
	d.catcher:SetShown(lockMode and true or false)
end

function fitSearch()
	local box = BagItemSearchBox
	if not box or not lockButton then return end
	local shift = lockButton:GetWidth() + 4
	local points, hasRight = {}, false
	for i = 1, box:GetNumPoints() do
		points[i] = { box:GetPoint(i) }
		if points[i][1]:find("RIGHT") then hasRight = true end
	end
	if hasRight then
		local changed
		for _, p in ipairs(points) do
			if p[1]:find("RIGHT") and (not box.LGBagLockX or math.abs(p[4] - box.LGBagLockX) > 1) then
				p[4] = p[4] - shift
				box.LGBagLockX = p[4]
				changed = true
			end
		end
		if changed then
			box:ClearAllPoints()
			for _, p in ipairs(points) do box:SetPoint(unpack(p, 1, 5)) end
		end
	else
		local w = box:GetWidth()
		if not box.LGBagLockW or math.abs(w - box.LGBagLockW) > 1 then
			box.LGBagLockW = w - shift
			box:SetWidth(box.LGBagLockW)
		end
	end
end

function refresh()
	if not db then return end
	fitSearch()
	for _, frame in ipairs(bagFrames()) do
		if frame:IsShown() then
			for _, btn in ipairs(itemButtons(frame)) do paint(btn) end
		end
	end
end

function setMode(on)
	lockMode = on
	if lockButton then
		setIcon(lockButton, on)
		lockButton.active:SetShown(on)
	end
	refresh()
end

local function groupOf(it)
	if it.id == HEARTHSTONE then return 1 end
	if it.class == 0 then
		if it.sub ~= 5 then return 4 end
		return isDrink(it.id) and 3 or 2
	end
	if it.class == 2 then return 5 end
	if it.class == 4 then return 6 end
	if it.class == 7 or it.class == 5 or it.class == 3 then return 7 end
	if it.class == 12 then return 8 end
	return 9
end

local function itemData(b, s, info)
	local link = info.hyperlink
	local name, _, quality, _, _, _, _, maxStack, _, _, _, classID, subID, _, _, _, reagent = itemInfo(link)
	local it = {
		b = b, s = s, id = info.itemID, link = link, count = info.stackCount or 1,
		name = name or link, quality = info.quality or quality or 1,
		class = classID or 15, sub = subID or 0, max = maxStack or 1,
		reagent = reagent, family = itemFamily(info.itemID) or 0,
		busy = info.isLocked,
	}
	it.group = groupOf(it)
	return it
end

local function snapshot()
	local bags, slots, cur = {}, {}, {}
	local hasFlags = FLAGS and C.GetBagSlotFlag
	for b = 0, LAST_BAG do
		local size = C.GetContainerNumSlots(b)
		if size > 0 and not (hasFlags and FLAGS.DisableAutoSort and C.GetBagSlotFlag(b, FLAGS.DisableAutoSort)) then
			local _, family = C.GetContainerNumFreeSlots(b)
			local bag = { id = b, size = size, ptr = 1, back = size, family = family or 0, reagent = REAGENT_BAG == b }
			bag.exclusive = bag.reagent or bag.family ~= 0
			if hasFlags and not bag.exclusive then
				for flag, fn in pairs(FILTERS) do
					if C.GetBagSlotFlag(b, flag) then bag.filter = fn end
				end
			end
			bags[#bags + 1] = bag
			for s = 1, size do
				local k = key(b, s)
				slots[#slots + 1] = { b = b, s = s, k = k, bag = bag }
				local info = getInfo(b, s)
				if info then cur[k] = itemData(b, s, info) end
			end
		end
	end
	return bags, slots, cur
end

local function fits(bag, it)
	if bag.reagent then return it.reagent and true or false end
	if bag.family ~= 0 then return bit.band(it.family, bag.family) ~= 0 end
	return true
end

local function before(a, b)
	local ja, jb = a.quality == 0, b.quality == 0
	if ja ~= jb then return jb end
	if a.group ~= b.group then return a.group < b.group end
	if a.quality ~= b.quality then return a.quality > b.quality end
	if a.class ~= b.class then return a.class < b.class end
	if a.sub ~= b.sub then return a.sub < b.sub end
	if a.name ~= b.name then return a.name < b.name end
	if a.id ~= b.id then return a.id < b.id end
	if a.link ~= b.link then return a.link < b.link end
	return a.count > b.count
end

local function same(a, b)
	if not a or not b then return a == b end
	return a.link == b.link and a.count == b.count
end

local function plan(bags, cur)
	local normal, junk = {}, {}
	for k, it in pairs(cur) do
		if not lockAt[k] then table.insert(it.quality == 0 and junk or normal, it) end
	end
	table.sort(normal, before)
	table.sort(junk, before)
	local desired = {}
	local function free(bag, i)
		local k = key(bag.id, i)
		return not lockAt[k] and not desired[k]
	end
	local function put(bag, it)
		while bag.ptr <= bag.size and not free(bag, bag.ptr) do bag.ptr = bag.ptr + 1 end
		if bag.ptr > bag.size then return false end
		desired[key(bag.id, bag.ptr)] = it
		return true
	end
	local function putBack(bag, it)
		while bag.back >= 1 and not free(bag, bag.back) do bag.back = bag.back - 1 end
		if bag.back < 1 then return false end
		desired[key(bag.id, bag.back)] = it
		return true
	end
	local function run(items, accept, putFn, order)
		local remaining = {}
		for _, it in ipairs(items) do
			local placed
			for _, bag in ipairs(order) do
				if accept(bag, it) and putFn(bag, it) then placed = true break end
			end
			if not placed then remaining[#remaining + 1] = it end
		end
		return remaining
	end
	local function exclusive(bag, it) return bag.exclusive and fits(bag, it) end
	local function filtered(bag, it) return bag.filter and bag.filter(it) end
	local function general(bag) return not bag.exclusive end
	local reversed = {}
	for i = #bags, 1, -1 do reversed[#reversed + 1] = bags[i] end
	normal = run(normal, exclusive, put, bags)
	normal = run(normal, filtered, put, bags)
	junk = run(junk, exclusive, put, bags)
	junk = run(junk, filtered, put, bags)
	run(normal, general, put, bags)
	run(junk, general, putBack, reversed)
	return desired
end

local function findMerges(slots, cur)
	local groups, list = {}, {}
	for _, sl in ipairs(slots) do
		local it = cur[sl.k]
		if it and it.count < it.max then
			groups[it.id] = groups[it.id] or {}
			table.insert(groups[it.id], it)
		end
	end
	for _, g in pairs(groups) do
		if #g > 1 then
			table.sort(g, function(x, y) return x.count > y.count end)
			local dest = g[1]
			for _, it in ipairs(g) do
				if lockAt[key(it.b, it.s)] then dest = it break end
			end
			for _, src in ipairs(g) do
				if src ~= dest and not lockAt[key(src.b, src.s)] then
					list[#list + 1] = { src, dest }
					break
				end
			end
		end
	end
	return list
end

local function nextMoves(bags, slots, cur)
	local moves, used = {}, {}
	local function add(from, to, mayHold)
		used[key(from.b, from.s)], used[key(to.b, to.s)] = true, true
		moves[#moves + 1] = { from, to, mayHold = mayHold }
	end
	for _, pair in ipairs(findMerges(slots, cur)) do add(pair[1], pair[2]) end
	if #moves > 0 then return moves end
	local desired = plan(bags, cur)
	for _, T in ipairs(slots) do
		local want = desired[T.k]
		if want and not cur[T.k] and not used[T.k] then
			for _, S in ipairs(slots) do
				local it = cur[S.k]
				if it and not used[S.k] and not lockAt[S.k] and same(it, want) and not same(it, desired[S.k]) then
					add(S, T)
					break
				end
			end
		end
	end
	for _, T in ipairs(slots) do
		local want, have = desired[T.k], cur[T.k]
		if want and have and not used[T.k] and not same(want, have) then
			for _, S in ipairs(slots) do
				local it = cur[S.k]
				if S.k ~= T.k and it and not used[S.k] and not lockAt[S.k] and same(it, want)
					and not same(it, desired[S.k]) and fits(S.bag, have) then
					add(S, T, true)
					break
				end
			end
		end
	end
	if #moves > 0 then return moves end
	for _, T in ipairs(slots) do
		local want, have = desired[T.k], cur[T.k]
		if want and not same(want, have) then
			if not have then return false end
			for pass = 1, 2 do
				for _, E in ipairs(slots) do
					if not cur[E.k] and not lockAt[E.k] and fits(E.bag, have) and (pass == 2 or not desired[E.k]) then
						return { { T, E } }
					end
				end
			end
			return false
		end
	end
end

local sorter = CreateFrame("Frame")
sorter:Hide()
local rounds, stalls, lastSig, returnTo, pending, actionTime

local function finish(message)
	sorter:Hide()
	returnTo, pending = nil, false
	if message then print("|cff4da6ffLG Bag Lock:|r " .. message) end
end

local function step()
	if CursorHasItem() then
		if not returnTo then return finish("sort stopped: unexpected item on cursor.") end
		C.PickupContainerItem(returnTo.b, returnTo.s)
		returnTo = nil
		pending, actionTime = true, GetTime()
		return
	end
	if pending and GetTime() - actionTime < 1 then return end
	pending, returnTo = false, nil
	local bags, slots, cur = snapshot()
	for _, it in pairs(cur) do
		if it.busy then return end
	end
	local sig = {}
	for _, sl in ipairs(slots) do
		local it = cur[sl.k]
		sig[#sig + 1] = it and (it.link .. it.count) or "-"
	end
	sig = table.concat(sig, "|")
	stalls = sig == lastSig and stalls + 1 or 0
	lastSig = sig
	if stalls >= 3 then return finish("sort stalled.") end
	local moves = nextMoves(bags, slots, cur)
	if moves == nil then return finish() end
	rounds = rounds + 1
	if not moves or rounds > 300 then return finish("not enough free space to finish sorting.") end
	for _, m in ipairs(moves) do
		local from, to = m[1], m[2]
		C.PickupContainerItem(from.b, from.s)
		C.PickupContainerItem(to.b, to.s)
		if CursorHasItem() then
			C.PickupContainerItem(from.b, from.s)
		elseif m.mayHold then
			returnTo = from
			break
		end
	end
	pending, actionTime = true, GetTime()
end

sorter:SetScript("OnUpdate", step)

local function startSort()
	if sorter:IsShown() then return end
	if CursorHasItem() then return print("|cff4da6ffLG Bag Lock:|r clear your cursor first.") end
	if SOUNDKIT and SOUNDKIT.UI_BAG_SORTING_01 then PlaySound(SOUNDKIT.UI_BAG_SORTING_01) end
	rounds, stalls, lastSig, returnTo, pending = 0, 0, nil, nil, false
	sorter:Show()
end

local function createLockButton(sortButton)
	local b = CreateFrame("Button", "LGBagLockButton", sortButton)
	b:SetSize(22, 22)
	b:SetPoint("RIGHT", sortButton, "LEFT", 0, 0)
	b:SetFrameLevel(sortButton:GetFrameLevel() + 1)
	setIcon(b, false)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b.active = b:CreateTexture(nil, "OVERLAY")
	b.active:SetAllPoints()
	b.active:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	b.active:SetBlendMode("ADD")
	b.active:Hide()
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function(_, button)
		setMode(button ~= "RightButton" and not lockMode)
	end)
	b:SetScript("OnHide", function() if lockMode then setMode(false) end end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Lock Items")
		GameTooltip:AddLine("Click an item to lock or unlock its slot. Sorting never moves locked items.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" then
		if name ~= ADDON then return end
		LGBagLockDB = LGBagLockDB or {}
		db = LGBagLockDB
		db.locks = db.locks or {}
		rebuildIndex()
		for _, frame in ipairs(bagFrames()) do
			if frame.UpdateItems then hooksecurefunc(frame, "UpdateItems", refresh) end
			if frame.UpdateSearchBox then hooksecurefunc(frame, "UpdateSearchBox", fitSearch) end
			frame:HookScript("OnShow", refresh)
		end
		local sortButton = BagItemAutoSortButton
		if sortButton then
			sortButton:SetScript("OnClick", startSort)
			lockButton = createLockButton(sortButton)
		end
		events:UnregisterEvent("ADDON_LOADED")
		events:RegisterEvent("BAG_UPDATE_DELAYED")
		events:RegisterEvent("PLAYER_REGEN_DISABLED")
	elseif event == "BAG_UPDATE_DELAYED" then
		reconcile()
		ready = true
		pending = false
		refresh()
	elseif event == "PLAYER_REGEN_DISABLED" then
		if lockMode then setMode(false) end
	end
end)
