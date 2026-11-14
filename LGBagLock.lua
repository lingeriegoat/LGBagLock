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

local function withCount(it, n)
	local copy = {}
	for k, v in pairs(it) do copy[k] = v end
	copy.count = n
	return copy
end

local function makeOps(bags, slots, p, excluded, limit)
	local desired = plan(bags, p)
	local ops, used, work = {}, {}, false
	local function free(k)
		return not excluded[k] and not used[k] and not lockAt[k]
	end
	for _, T in ipairs(slots) do
		local want, have = desired[T.k], p[T.k]
		if want and not same(have, want) then
			work = true
			if #ops < limit and free(T.k) then
				local best, any
				for _, S in ipairs(slots) do
					local it = p[S.k]
					if S.k ~= T.k and it and free(S.k) and same(it, want) and not same(it, desired[S.k])
						and (not have or fits(S.bag, have)) then
						if have and same(desired[S.k], have) then best = S break end
						any = any or S
					end
				end
				local S = best or any
				if S then
					used[S.k], used[T.k] = true, true
					ops[#ops + 1] = { S, T, swap = have ~= nil }
				end
			end
		end
	end
	if #ops == 0 and work then
		for _, T in ipairs(slots) do
			local want, have = desired[T.k], p[T.k]
			if want and have and not same(have, want) and free(T.k) then
				for pass = 1, 2 do
					for _, E in ipairs(slots) do
						if not p[E.k] and free(E.k) and fits(E.bag, have) and (pass == 2 or not desired[E.k]) then
							return { { T, E } }, true
						end
					end
				end
			end
		end
	end
	return ops, work
end

local sorter = CreateFrame("Frame")
sorter:Hide()
local inflight, swapMode, probe, returnTo, lastProgress, failures, elapsed = {}, nil, false, nil, 0, 0, 0

local function finish(message)
	sorter:Hide()
	inflight, returnTo, probe = {}, nil, false
	if message then print("|cff4da6ffLG Bag Lock:|r " .. message) end
end

local function confirmed(e)
	local info = getInfo(e.b, e.s)
	if info and info.isLocked then return false end
	if not e.item then return info == nil end
	return info ~= nil and info.hyperlink == e.item.link and (info.stackCount or 1) == e.item.count
end

local function step(_, dt)
	elapsed = elapsed + dt
	if elapsed < 0.05 then return end
	elapsed = 0
	local now = GetTime()
	if CursorHasItem() then
		if not returnTo then
			ClearCursor()
			return finish("sort stopped: unexpected item on cursor.")
		end
		C.PickupContainerItem(returnTo.b, returnTo.s)
		returnTo = nil
		if probe then swapMode, probe = "hold", false end
		lastProgress = now
		return
	end
	local bags, slots, cur = snapshot()
	for k, e in pairs(inflight) do
		if confirmed(e) then
			inflight[k] = nil
			lastProgress = now
		elseif now - e.t > 3 then
			inflight[k] = nil
			failures = failures + 1
		end
	end
	if failures >= 8 then return finish("sort stopped: moves are being rejected.") end
	local idle = next(inflight) == nil
	if idle then
		returnTo = nil
		if probe then swapMode, probe = "direct", false end
	end
	local p, excluded, slotAt = {}, {}, {}
	for k, it in pairs(cur) do
		p[k] = it
		if it.busy then excluded[k] = true end
	end
	for k, e in pairs(inflight) do
		p[k] = e.item or nil
		excluded[k] = true
	end
	for _, sl in ipairs(slots) do slotAt[sl.k] = sl end
	local ops, work
	local merge = idle and findMerges(slots, cur)[1]
	if merge then
		ops, work = { { slotAt[key(merge[1].b, merge[1].s)], slotAt[key(merge[2].b, merge[2].s)], merge = true } }, true
	else
		ops, work = makeOps(bags, slots, p, excluded, 12)
	end
	if not work and idle then return finish() end
	if #ops == 0 then
		if now - lastProgress > 5 then return finish("sort stopped: no progress.") end
		return
	end
	if swapMode ~= "direct" then
		local moves = {}
		for _, op in ipairs(ops) do
			if not op.swap and not op.merge then moves[#moves + 1] = op end
		end
		if #moves > 0 then
			ops = moves
		elseif idle then
			ops = { ops[1] }
		else
			return
		end
	end
	for _, op in ipairs(ops) do
		local S, T = op[1], op[2]
		local a, b = p[S.k], p[T.k]
		C.PickupContainerItem(S.b, S.s)
		C.PickupContainerItem(T.b, T.s)
		if op.merge then
			local total = a.count + b.count
			local dst = math.min(total, b.max)
			inflight[T.k] = { b = T.b, s = T.s, item = withCount(b, dst), t = now }
			inflight[S.k] = { b = S.b, s = S.s, item = total > dst and withCount(a, total - dst) or false, t = now }
			returnTo = S
		else
			inflight[S.k] = { b = S.b, s = S.s, item = b or false, t = now }
			inflight[T.k] = { b = T.b, s = T.s, item = a, t = now }
			if op.swap and swapMode ~= "direct" then
				returnTo = S
				probe = swapMode == nil
			end
		end
	end
	lastProgress = now
end

sorter:SetScript("OnUpdate", step)

local function startSort()
	if sorter:IsShown() then return end
	if CursorHasItem() then return print("|cff4da6ffLG Bag Lock:|r clear your cursor first.") end
	if SOUNDKIT and SOUNDKIT.UI_BAG_SORTING_01 then PlaySound(SOUNDKIT.UI_BAG_SORTING_01) end
	inflight, returnTo, probe, lastProgress, failures, elapsed = {}, nil, false, GetTime(), 0, 0
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
		refresh()
	elseif event == "PLAYER_REGEN_DISABLED" then
		if lockMode then setMode(false) end
	end
end)
