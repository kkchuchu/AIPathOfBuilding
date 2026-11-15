-- Path of Building
--
-- Module: LiveBridge
-- A file-based bridge that lets external tools (scripts, AI assistants, ...) see and
-- drive the build that is currently open in Path of Building.
--
--   <bridgeDir>/build.xml        current build (same format as a saved build), rewritten on every change
--   <bridgeDir>/stats.json       structured summary + every calculated stat, rewritten on every change
--   <bridgeDir>/summary.txt      short human-readable summary
--   <bridgeDir>/commands/*.json  command queue: { "id": "...", "cmd": "...", "args": { ... } }
--   <bridgeDir>/responses/<id>.json   result of each command
--
-- <bridgeDir> defaults to "<PoB user folder>/LiveBridge" and can be overridden with the
-- POB_BRIDGE_DIR environment variable. See docs/live-bridge.md for the full protocol.
--
local dkjson = require("dkjson")

local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format

local bridge = {
	version = "1.1.0",
	-- Set POB_BRIDGE=0 to turn the bridge off completely
	enabled = os.getenv("POB_BRIDGE") ~= "0" and not LIVEBRIDGE_DISABLED,
	commandsProcessed = 0,
}

local KEY_STATS = {
	"FullDPS", "CombinedDPS", "TotalDPS", "TotalDot", "AverageHit", "HitChance", "Speed", "CritChance", "CritMultiplier",
	"Life", "LifeUnreserved", "EnergyShield", "Mana", "ManaUnreserved", "TotalEHP",
	"Armour", "Evasion", "PhysicalDamageReduction", "EffectiveBlockChance", "EffectiveSpellBlockChance", "SpellSuppressionChance",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
	"LifeRegenRecovery", "Str", "Dex", "Int", "MovementSpeedMod",
}

local MIN_EXPORT_INTERVAL = 300 -- ms between state exports
local POLL_INTERVAL = 100       -- ms between command queue scans
local BACKGROUND_FRAME_MS = 100      -- idle frame pacing while PoB is not the foreground window
local BACKGROUND_DEEP_FRAME_MS = 250 -- after BACKGROUND_DEEP_AFTER ms without commands or focus
local BACKGROUND_DEEP_AFTER = 3000

local dirReady = false
local lastExportBuild, lastExportRevision, lastExportView
local lastExportTime = 0
local lastPollTime = 0
local pending = nil -- response waiting for the build to finish recalculating

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function bridgeDir()
	if not bridge.dir then
		local dir = os.getenv("POB_BRIDGE_DIR")
		if not dir or dir == "" then
			dir = (main and main.userPath or GetUserPath and GetUserPath() or "./") .. "LiveBridge"
		end
		bridge.dir = dir:gsub("\\", "/"):gsub("/$", "")
	end
	return bridge.dir
end

local function ensureDirs()
	if dirReady then return end
	local dir = bridgeDir()
	MakeDir(dir)
	MakeDir(dir .. "/commands")
	MakeDir(dir .. "/responses")
	dirReady = true
end

local function writeFileAtomic(path, text)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "wb")
	if not f then return false end
	f:write(text)
	f:close()
	os.remove(path)
	return os.rename(tmp, path)
end

-- Force a table to encode as a JSON object even when empty
local function object(t)
	return setmetatable(t or { }, { __jsontype = "object" })
end

local function stripColors(s)
	return s and (s:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end

local function isFiniteNumber(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function plainValues(t)
	local out = object()
	if type(t) ~= "table" then return out end
	for k, v in pairs(t) do
		if type(k) == "string" and (type(v) == "string" or type(v) == "boolean" or isFiniteNumber(v)) then
			out[k] = v
		end
	end
	return out
end

local function keyStats(output)
	local out = object()
	for _, stat in ipairs(KEY_STATS) do
		if isFiniteNumber(output[stat]) then
			out[stat] = output[stat]
		end
	end
	return out
end

local function statDiff(before, after, wanted)
	local diff = object()
	local keys = wanted or KEY_STATS
	for _, stat in ipairs(keys) do
		local a, b = before[stat], after[stat]
		if isFiniteNumber(a) and isFiniteNumber(b) and a ~= b then
			diff[stat] = { before = a, after = b, change = b - a, percent = a ~= 0 and (b - a) / math.abs(a) * 100 or nil }
		end
	end
	return diff
end

local function currentBuild()
	if main.mode == "BUILD" then
		return main.modes["BUILD"]
	end
end

local function requireBuild()
	local build = currentBuild()
	if not build then
		error("No build is open. Open or import a build first.", 0)
	end
	return build
end

local function lower(s)
	return tostring(s or ""):lower()
end

---------------------------------------------------------------------------
-- State export
---------------------------------------------------------------------------

local function nodeInfo(node, spec)
	local info = {
		id = node.id,
		name = node.dn,
		type = node.type,
		allocated = node.alloc and true or false,
		ascendancy = node.ascendancyName,
		stats = node.sd,
	}
	if not node.alloc and node.pathDist and node.pathDist < 1000 then
		info.pointsToReach = node.pathDist
	end
	if node.type == "Mastery" and spec and spec.masterySelections[node.id] then
		local effect = spec.tree.masteryEffects[spec.masterySelections[node.id]]
		info.masteryEffect = effect and table.concat(effect.sd, " / ")
	end
	return info
end

local function collectSkills(build)
	local groups = { }
	for index, sg in ipairs(build.skillsTab.socketGroupList) do
		local gems = { }
		for _, gem in ipairs(sg.gemList or { }) do
			t_insert(gems, {
				name = gem.nameSpec,
				level = gem.level,
				quality = gem.quality,
				enabled = gem.enabled ~= false,
				support = gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support or nil,
			})
		end
		local activeSkills = { }
		for _, skill in ipairs(sg.displaySkillList or { }) do
			if skill.activeEffect and skill.activeEffect.grantedEffect then
				t_insert(activeSkills, skill.activeEffect.grantedEffect.name)
			end
		end
		t_insert(groups, {
			index = index,
			label = sg.displayLabel or sg.label,
			slot = sg.slot,
			enabled = sg.enabled ~= false,
			isMain = index == build.mainSocketGroup,
			mainActiveSkill = sg.mainActiveSkill,
			activeSkills = activeSkills,
			gems = gems,
		})
	end
	return groups
end

local function collectItems(build, includeRaw)
	local itemsTab = build.itemsTab
	local equipped = { }
	for _, slot in ipairs(itemsTab.orderedSlots or { }) do
		local item = slot.selItemId and slot.selItemId ~= 0 and itemsTab.items[slot.selItemId]
		if item and (not slot.shown or slot:shown()) then
			local entry = { slot = slot.slotName, itemId = item.id, name = item.name, rarity = item.rarity, base = item.baseName }
			if includeRaw then
				entry.text = item:BuildRaw()
			end
			t_insert(equipped, entry)
		end
	end
	return equipped
end

local function collectState(build)
	local output = build.calcsTab.mainOutput or { }
	local spec = build.spec
	local state = {
		exportedAt = os.date("%Y-%m-%d %H:%M:%S"),
		buildName = build.buildName,
		fileName = build.dbFileName,
		unsavedChanges = build.unsaved or false,
		viewMode = build.viewMode,
		level = build.characterLevel,
		class = spec.curClassName,
		ascendancy = spec.curAscendClassName,
		treeVersion = spec.treeVersion,
	}

	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup or 1]
	if mainGroup then
		state.mainSocketGroup = mainGroup.displayLabel or mainGroup.label
		local active = mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
		if active and active.activeEffect and active.activeEffect.grantedEffect then
			state.mainSkill = active.activeEffect.grantedEffect.name
		end
	end

	local used, ascUsed = spec:CountAllocNodes()
	local keystones, notables = { }, { }
	for _, node in pairs(spec.allocNodes) do
		if node.type == "Keystone" then
			t_insert(keystones, node.dn)
		elseif node.type == "Notable" then
			t_insert(notables, node.dn)
		end
	end
	t_sort(keystones)
	t_sort(notables)
	state.passives = { pointsUsed = used, ascendancyPointsUsed = ascUsed, keystones = keystones, notables = notables }
	state.skills = collectSkills(build)
	state.items = collectItems(build, false)
	state.keyStats = keyStats(output)
	state.stats = plainValues(output)
	if output.Minion then
		state.minionStats = plainValues(output.Minion)
	end
	return state
end

local function summaryText(state)
	local s = state.stats
	local function v(x) return x == nil and "-" or tostring(x) end
	local lines = {
		s_format("[%s] %s%s", state.exportedAt, v(state.buildName), state.unsavedChanges and " (unsaved)" or ""),
		s_format("Level %s %s / %s  |  tab: %s  |  passives: %s (+%s asc)", v(state.level), v(state.class), v(state.ascendancy), v(state.viewMode), v(state.passives.pointsUsed), v(state.passives.ascendancyPointsUsed)),
		s_format("Main skill: %s (%s)", v(state.mainSkill), v(state.mainSocketGroup)),
		s_format("DPS: Full=%s Combined=%s Hit=%s Speed=%s", v(s.FullDPS), v(s.CombinedDPS), v(s.AverageHit), v(s.Speed)),
		s_format("Life=%s ES=%s Mana=%s EHP=%s", v(s.Life), v(s.EnergyShield), v(s.Mana), v(s.TotalEHP)),
		s_format("Res F/C/L/Ch: %s/%s/%s/%s  Armour=%s Evasion=%s", v(s.FireResist), v(s.ColdResist), v(s.LightningResist), v(s.ChaosResist), v(s.Armour), v(s.Evasion)),
		"Keystones: " .. table.concat(state.passives.keystones, ", "),
	}
	return table.concat(lines, "\n") .. "\n"
end

function bridge:ExportState(build)
	ensureDirs()
	local dir = bridgeDir()
	local xml = build:SaveDB("LiveBridge")
	if xml then
		writeFileAtomic(dir .. "/build.xml", xml)
	end
	local state = collectState(build)
	writeFileAtomic(dir .. "/stats.json", dkjson.encode(state, { indent = true }))
	writeFileAtomic(dir .. "/summary.txt", summaryText(state))
end

-- Called from buildMode:OnFrame after the build has been recalculated
function bridge:OnBuildFrame(build)
	if not self.enabled then return end
	if build == lastExportBuild and build.outputRevision == lastExportRevision and build.viewMode == lastExportView then
		return
	end
	local now = GetTime()
	if now - lastExportTime < MIN_EXPORT_INTERVAL then
		return
	end
	lastExportBuild, lastExportRevision, lastExportView = build, build.outputRevision, build.viewMode
	lastExportTime = now
	local ok, err = pcall(self.ExportState, self, build)
	if not ok then
		ConPrintf("LiveBridge export error: %s", tostring(err))
	end
end

---------------------------------------------------------------------------
-- Lookups
---------------------------------------------------------------------------

-- Resolve a node by numeric id or (case-insensitive) name.
-- Names are not unique ("Strength", "Life" ...). When ambiguous, the closest
-- unallocated node is used for allocation, or the allocated one for deallocation.
local function findNode(spec, ref, preferAllocated)
	if ref == nil then error("Missing node id or name", 0) end
	local id = tonumber(ref)
	if id then
		local node = spec.nodes[id]
		if not node then error("No passive node with id " .. id, 0) end
		return node
	end
	local name = lower(ref)
	local best
	for _, node in pairs(spec.nodes) do
		if lower(node.dn) == name then
			if preferAllocated then
				if node.alloc and (not best or not best.alloc) then best = node
				elseif not best then best = node end
			else
				local dist = node.alloc and math.huge or (node.pathDist or math.huge)
				local bestDist = best and (best.alloc and math.huge or (best.pathDist or math.huge)) or nil
				if not best or dist < bestDist then best = node end
			end
		end
	end
	if not best then error("No passive node named '" .. tostring(ref) .. "'", 0) end
	return best
end

local function findClass(spec, name)
	for classId, class in pairs(spec.tree.classes) do
		if lower(class.name) == lower(name) then
			return classId, class
		end
	end
	error("Unknown class '" .. tostring(name) .. "'", 0)
end

local function findSlot(itemsTab, name)
	if not name then return nil end
	if itemsTab.slots[name] then return itemsTab.slots[name] end
	for slotName, slot in pairs(itemsTab.slots) do
		if lower(slotName) == lower(name) then return slot end
	end
	error("Unknown item slot '" .. tostring(name) .. "'", 0)
end

local function parseItem(text)
	if type(text) ~= "string" or text == "" then
		error("Missing item text (paste the item as copied in-game with Ctrl+C)", 0)
	end
	local item = new("Item")
	item:Item((text:gsub("\r\n", "\n")))
	if not item.base then
		error("Could not parse item (unknown base type)", 0)
	end
	item:NormaliseQuality()
	item:BuildModList()
	return item
end

local function bestSlotForItem(itemsTab, item, requested)
	if requested then
		local slot = findSlot(itemsTab, requested)
		if not itemsTab:IsItemValidForSlot(item, slot.slotName) then
			error(s_format("'%s' cannot be equipped in slot '%s'", item.name, slot.slotName), 0)
		end
		return slot
	end
	local primary = item:GetPrimarySlot()
	if primary and itemsTab.slots[primary] then
		return itemsTab.slots[primary]
	end
	for _, slot in ipairs(itemsTab.orderedSlots) do
		if itemsTab:IsItemValidForSlot(item, slot.slotName) then
			return slot
		end
	end
	error("No valid slot found for '" .. tostring(item.name) .. "'", 0)
end

local function markChanged(build)
	build.buildFlag = true
	build.modFlag = true
end

---------------------------------------------------------------------------
-- Commands
-- Each handler returns (result, mutated). When mutated is true the response is
-- delayed until the build has been recalculated, and includes the new key stats.
---------------------------------------------------------------------------

local commands = { }

commands.ping = function()
	return { pong = true, mode = main.mode, bridgeVersion = bridge.version, version = launch.versionNumber }
end

commands.help = function()
	local names = { }
	for name in pairs(commands) do t_insert(names, name) end
	t_sort(names)
	return { commands = names }
end

commands.getState = function(args)
	local state = collectState(requireBuild())
	if not args.allStats then
		state.stats = nil
		state.minionStats = nil
	end
	return state
end

commands.getStats = function(args)
	local build = requireBuild()
	local output = build.calcsTab.mainOutput
	if args.stats then
		local out = { }
		for _, stat in ipairs(args.stats) do out[stat] = output[stat] end
		return out
	end
	return plainValues(output)
end

-- Build list / open / new ---------------------------------------------------

commands.listBuilds = function()
	local list = { }
	local handle = NewFileSearch(main.buildPath .. "*.xml")
	while handle do
		t_insert(list, handle:GetFileName())
		if not handle:NextFile() then break end
	end
	t_sort(list)
	return { folder = main.buildPath, builds = list }
end

-- Build names are plain file names inside the build folder: no paths
local function safeBuildName(name)
	if type(name) ~= "string" or name == "" then error("Missing 'name'", 0) end
	name = name:gsub("%.xml$", "")
	if name:find('[/\\:*?"<>|]') or name:find("%.%.") then
		error("Invalid build name '" .. name .. "' (no paths or special characters)", 0)
	end
	return name
end

commands.openBuild = function(args)
	local name = safeBuildName(args.name)
	local fileName = main.buildPath .. name .. ".xml"
	local f = io.open(fileName, "r")
	if not f then error("Build not found: " .. fileName, 0) end
	f:close()
	main:SetMode("BUILD", fileName, name)
	return { opened = fileName }, true
end

commands.newBuild = function(args)
	main:SetMode("BUILD", false, args.name or "Unnamed build")
	return { created = true }, true
end

-- Import / export -----------------------------------------------------------

commands.importBuild = function(args)
	local xmlText = args.xml
	if not xmlText then
		local code = args.code or error("Provide 'code' (PoB build code) or 'xml'", 0)
		code = code:gsub("%s", "")
		xmlText = Inflate(common.base64.decode(code:gsub("-", "+"):gsub("_", "/")))
		if not xmlText then error("Invalid build code", 0) end
	end
	main:SetMode("BUILD", false, args.name or "Imported build", xmlText)
	return { imported = true }, true
end

commands.exportCode = function()
	local build = requireBuild()
	local xml = build:SaveDB("code")
	local code = common.base64.encode(Deflate(xml)):gsub("+", "-"):gsub("/", "_")
	return { code = code }
end

local function saveBuild(build, name)
	if name then
		name = safeBuildName(name)
		build.dbFileName = main.buildPath .. name .. ".xml"
		build.buildName = name
		build.dbFileSubPath = ""
	end
	if not build.dbFileName then
		error("Build has never been saved; pass 'name'", 0)
	end
	local xml = build:SaveDB(build.dbFileName)
	local f = io.open(build.dbFileName, "w+")
	if not f then error("Cannot write " .. build.dbFileName, 0) end
	f:write(xml)
	f:close()
	build:ResetModFlags()
	build.spec:SetWindowTitleWithBuildClass()
	return build.dbFileName
end

commands.save = function(args)
	return { saved = saveBuild(requireBuild(), args.name) }
end

-- Async commands: a handler can return (nil, "async", step). step() is called once per frame
-- on the main thread until it returns (true, result) or raises an error. (Not a coroutine:
-- LaunchSubScript, and so launch:DownloadPage, crashes the runtime when called from one.)

local function buildIsSettled()
	if main.newMode then return false end
	local build = currentBuild()
	return not (build and build.buildFlag)
end

-- Import a character straight from pathofexile.com (public profile), like Import/Export ->
-- "Import from website", but without any confirmation popup.
commands.importCharacter = function(args)
	local account = type(args.account) == "string" and args.account or error("Missing 'account' (e.g. \"name#1234\")", 0)
	if not account:match("%S[#%-]%d%d%d%d%s*$") then
		error("Account name needs its discriminator, e.g. " .. account .. "#1234", 0)
	end
	local character = type(args.character) == "string" and args.character ~= "" and args.character or error("Missing 'character'", 0)
	if args.name then safeBuildName(args.name) end -- validate before downloading anything
	local intoNewBuild = args.newBuild ~= false or not currentBuild()

	local fetched, fetchErr
	if not common.classes.ImportTab then LoadModule("Classes/ImportTab") end
	common.classes.ImportTab.FetchSiteCharacter(args.realm or "pc", account, character, function(result, err)
		fetched, fetchErr = result, err or (not result and "Download failed") or nil
	end)

	local stage, deadline = "downloading the character from pathofexile.com", GetTime() + 90000
	local function nextStage(name, timeout)
		stage, deadline = name, GetTime() + timeout
	end
	return nil, "async", function()
		if GetTime() > deadline then error("Timed out " .. stage, 0) end
		if fetchErr then error(fetchErr, 0) end
		if not fetched then return end
		if stage == "downloading the character from pathofexile.com" then
			if intoNewBuild then
				main:SetMode("BUILD", false, args.name or (fetched.accountName:gsub("#%d+$", "") .. " - " .. fetched.char.name))
			end
			nextStage("opening a new build", 10000)
		elseif stage == "opening a new build" then
			if main.newMode or not currentBuild() then return end
			local build = currentBuild()
			build.importTab:ImportSiteCharacter(fetched, {
				deleteJewels = args.deleteJewels, clearItems = args.clearItems, clearSkills = args.clearSkills, ignoreWeaponSwap = args.ignoreWeaponSwap,
			})
			markChanged(build)
			nextStage("recalculating the imported build", 30000)
		elseif stage == "recalculating the imported build" then
			if not buildIsSettled() then return end
			local build = requireBuild()
			local saved = args.name and saveBuild(build, args.name) or nil
			local state = collectState(build)
			return true, {
				imported = { account = fetched.accountName, character = fetched.char.name, league = fetched.char.league, realm = fetched.realm.realmCode },
				newBuild = intoNewBuild,
				saved = saved,
				buildName = build.buildName,
				level = state.level,
				class = state.class,
				ascendancy = state.ascendancy,
				mainSkill = state.mainSkill,
				mainSocketGroup = state.mainSocketGroup,
				passives = { pointsUsed = state.passives.pointsUsed, ascendancyPointsUsed = state.passives.ascendancyPointsUsed, keystones = state.passives.keystones },
				equippedItems = #state.items,
				socketGroups = #state.skills,
				dps = { FullDPS = state.keyStats.FullDPS, CombinedDPS = state.keyStats.CombinedDPS, TotalDPS = state.keyStats.TotalDPS },
			}
		end
	end
end

-- Character -------------------------------------------------------------------

commands.setLevel = function(args)
	local build = requireBuild()
	local level = math.min(math.max(tonumber(args.level) or error("Missing 'level'", 0), 1), 100)
	build.characterLevel = level
	build.characterLevelAutoMode = false
	build.controls.characterLevel:SetText(level)
	build.controls.levelScalingButton.label = "Manual"
	build.configTab:BuildModList()
	markChanged(build)
	return { level = level }, true
end

commands.setClass = function(args)
	local build = requireBuild()
	local spec = build.spec
	local classId, class = findClass(spec, args.class or error("Missing 'class'", 0))
	if classId ~= spec.curClassId then
		spec:SelectClass(classId)
		spec:AddUndoState()
		markChanged(build)
	end
	return { class = class.name }, true
end

commands.setAscendancy = function(args)
	local build = requireBuild()
	local spec = build.spec
	local wanted = lower(args.ascendancy or error("Missing 'ascendancy'", 0))
	if args.class then
		local classId = findClass(spec, args.class)
		if classId ~= spec.curClassId then spec:SelectClass(classId) end
	end
	-- Search the current class first, then all classes
	local function search(classId, class)
		for ascendId, ascend in pairs(class.classes) do
			if lower(ascend.name) == wanted or (wanted == "none" and ascendId == 0) then
				return classId, ascendId, ascend
			end
		end
	end
	local classId, ascendId, ascend = search(spec.curClassId, spec.curClass)
	if not ascendId then
		for cid, class in pairs(spec.tree.classes) do
			classId, ascendId, ascend = search(cid, class)
			if ascendId then break end
		end
	end
	if not ascendId then error("Unknown ascendancy '" .. tostring(args.ascendancy) .. "'", 0) end
	if classId ~= spec.curClassId then spec:SelectClass(classId) end
	spec:SelectAscendClass(ascendId)
	spec:AddUndoState()
	markChanged(build)
	return { class = spec.curClassName, ascendancy = ascend.name }, true
end

-- Passive tree ----------------------------------------------------------------

commands.findNodes = function(args)
	local spec = requireBuild().spec
	local query = lower(args.query or "")
	local limit = tonumber(args.limit) or 30
	local types = args.type and { [args.type] = true }
	local results = { }
	for _, node in pairs(spec.nodes) do
		if (not types or types[node.type]) and (not args.allocated or node.alloc) and node.dn then
			local hit = query == "" or lower(node.dn):find(query, 1, true)
			if not hit and args.searchStats ~= false and node.sd then
				for _, line in ipairs(node.sd) do
					if lower(line):find(query, 1, true) then hit = true break end
				end
			end
			if hit then t_insert(results, node) end
		end
	end
	t_sort(results, function(a, b)
		local da = a.alloc and -1 or (a.pathDist or 1e9)
		local db = b.alloc and -1 or (b.pathDist or 1e9)
		if da ~= db then return da < db end
		return a.id < b.id
	end)
	local out = { }
	for i = 1, math.min(limit, #results) do
		t_insert(out, nodeInfo(results[i], spec))
	end
	return { total = #results, nodes = out }
end

commands.getNode = function(args)
	local spec = requireBuild().spec
	local node = findNode(spec, args.id or args.name)
	local info = nodeInfo(node, spec)
	if node.type == "Mastery" and node.masteryEffects then
		info.masteryOptions = { }
		for _, me in ipairs(node.masteryEffects) do
			local effect = spec.tree.masteryEffects[me.effect]
			if effect then t_insert(info.masteryOptions, { effectId = effect.id, stats = effect.sd }) end
		end
	end
	return info
end

local function applyMastery(spec, node, choice)
	local wanted = tonumber(choice)
	local selected
	for _, me in ipairs(node.masteryEffects or { }) do
		local effect = spec.tree.masteryEffects[me.effect]
		if effect then
			if wanted and effect.id == wanted then selected = effect break end
			if not wanted and lower(table.concat(effect.sd, " ")):find(lower(choice), 1, true) then selected = effect break end
		end
	end
	if not selected then error("No mastery effect on '" .. node.dn .. "' matches '" .. tostring(choice) .. "'", 0) end
	node.sd = selected.sd
	node.allMasteryOptions = false
	spec.tree:ProcessStats(node)
	spec.masterySelections[node.id] = selected.id
	return selected
end

commands.allocNode = function(args)
	local build = requireBuild()
	local spec = build.spec
	local refs = args.nodes or { args.id or args.name }
	local done = { }
	for _, ref in ipairs(refs) do
		local node = findNode(spec, ref, false)
		if node.type == "Mastery" then
			if not args.mastery then error("'" .. node.dn .. "' is a mastery; pass 'mastery' (effect id or text)", 0) end
			applyMastery(spec, node, args.mastery)
		end
		if not node.alloc then
			if not node.path then error("'" .. node.dn .. "' (" .. node.id .. ") is not reachable from the current tree", 0) end
			local cost = node.pathDist
			spec:AllocNode(node)
			t_insert(done, { id = node.id, name = node.dn, pointsSpent = cost })
		else
			t_insert(done, { id = node.id, name = node.dn, alreadyAllocated = true })
		end
	end
	spec:AddUndoState()
	markChanged(build)
	return { allocated = done }, true
end

commands.deallocNode = function(args)
	local build = requireBuild()
	local spec = build.spec
	local refs = args.nodes or { args.id or args.name }
	local done = { }
	for _, ref in ipairs(refs) do
		local node = findNode(spec, ref, true)
		if node.alloc then
			local removed = { }
			for _, dep in ipairs(node.depends) do t_insert(removed, dep.dn) end
			spec:DeallocNode(node)
			t_insert(done, { id = node.id, name = node.dn, removed = removed })
		end
	end
	spec:AddUndoState()
	markChanged(build)
	return { deallocated = done }, true
end

commands.resetTree = function()
	local build = requireBuild()
	build.spec:ResetNodes()
	build.spec:BuildAllDependsAndPaths()
	build.spec:AddUndoState()
	markChanged(build)
	return { reset = true }, true
end

commands.importTreeUrl = function(args)
	local build = requireBuild()
	local url = args.url or error("Missing 'url'", 0)
	local err = build.spec:DecodeURL(url)
	if err then error(err, 0) end
	build.spec:AddUndoState()
	markChanged(build)
	return { imported = true }, true
end

commands.exportTreeUrl = function()
	return { url = requireBuild().spec:EncodeURL() }
end

-- What-if: stat changes of allocating / removing nodes without touching the build
commands.whatIfNodes = function(args)
	local build = requireBuild()
	local spec = build.spec
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local override = { }
	local names = { }
	for _, ref in ipairs(args.add or { }) do
		local node = findNode(spec, ref, false)
		if not node.alloc then
			if not node.path then error("'" .. node.dn .. "' is not reachable", 0) end
			override.addNodes = override.addNodes or { }
			for _, pathNode in ipairs(node.path) do override.addNodes[pathNode] = true end
			t_insert(names, "+" .. node.dn .. " (" .. node.pathDist .. " pts)")
		end
	end
	for _, ref in ipairs(args.remove or { }) do
		local node = findNode(spec, ref, true)
		if node.alloc then
			override.removeNodes = override.removeNodes or { }
			for _, dep in ipairs(node.depends) do override.removeNodes[dep] = true end
			t_insert(names, "-" .. node.dn)
		end
	end
	local base = calcFunc({ }, true)
	local after = calcFunc(override, true)
	return { change = names, diff = statDiff(base, after, args.stats) }
end

-- Items -----------------------------------------------------------------------

commands.listItems = function(args)
	local build = requireBuild()
	local itemsTab = build.itemsTab
	local all = { }
	for _, id in ipairs(itemsTab.itemOrderList) do
		local item = itemsTab.items[id]
		local slot = itemsTab:GetEquippedSlotForItem(item)
		local entry = { itemId = id, name = item.name, rarity = item.rarity, base = item.baseName, equippedIn = slot and slot.slotName }
		if args.text then entry.text = item:BuildRaw() end
		t_insert(all, entry)
	end
	return { equipped = collectItems(build, args.text), items = all }
end

commands.addItem = function(args)
	local build = requireBuild()
	local itemsTab = build.itemsTab
	local item = parseItem(args.text)
	local slot
	if args.equip ~= false then
		slot = bestSlotForItem(itemsTab, item, args.slot)
	end
	itemsTab:AddItem(item, true)
	if slot then
		slot:SetSelItemId(item.id)
	end
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	markChanged(build)
	return { itemId = item.id, name = item.name, equippedIn = slot and slot.slotName }, true
end

commands.equipItem = function(args)
	local build = requireBuild()
	local itemsTab = build.itemsTab
	local slot = findSlot(itemsTab, args.slot or error("Missing 'slot'", 0))
	local id = tonumber(args.itemId) or 0
	if id ~= 0 then
		local item = itemsTab.items[id] or error("No item with id " .. tostring(args.itemId), 0)
		if not itemsTab:IsItemValidForSlot(item, slot.slotName) then
			error(s_format("'%s' cannot be equipped in slot '%s'", item.name, slot.slotName), 0)
		end
	end
	slot:SetSelItemId(id)
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	markChanged(build)
	return { slot = slot.slotName, itemId = id }, true
end

commands.removeItem = function(args)
	local build = requireBuild()
	local itemsTab = build.itemsTab
	local item = itemsTab.items[tonumber(args.itemId) or -1] or error("No item with id " .. tostring(args.itemId), 0)
	itemsTab:DeleteItem(item)
	markChanged(build)
	return { removed = item.name }, true
end

-- What-if: stat changes of swapping in an item, without touching the build
commands.whatIfItem = function(args)
	local build = requireBuild()
	local item = parseItem(args.text)
	local slot = bestSlotForItem(build.itemsTab, item, args.slot)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local base = calcFunc({ }, true)
	local after = calcFunc({ repSlotName = slot.slotName, repItem = item }, true)
	return { item = item.name, slot = slot.slotName, diff = statDiff(base, after, args.stats) }
end

-- Skills ----------------------------------------------------------------------

local function gemFromArg(g)
	if type(g) == "string" then g = { name = g } end
	local name = g.name or error("Gem entry is missing 'name'", 0)
	-- Accept in-game base names too ("Spell Echo Support", "Vaal Arc", ...)
	local gemId = data.gemForBaseName[lower(name)] or data.gemForBaseName[lower(name) .. " support"]
	return {
		gemId = gemId,
		nameSpec = name,
		level = tonumber(g.level) or 20,
		quality = tonumber(g.quality) or 0,
		enabled = g.enabled ~= false,
		count = 1,
		enableGlobal1 = true,
		enableGlobal2 = true,
	}
end

commands.listSkills = function()
	local build = requireBuild()
	return { mainSocketGroup = build.mainSocketGroup, groups = collectSkills(build) }
end

commands.addSkillGroup = function(args)
	local build = requireBuild()
	local skillsTab = build.skillsTab
	local group = { label = args.label or "", enabled = true, slot = args.slot, gemList = { } }
	for _, g in ipairs(args.gems or error("Missing 'gems'", 0)) do
		t_insert(group.gemList, gemFromArg(g))
	end
	t_insert(skillsTab.socketGroupList, group)
	skillsTab:ProcessSocketGroup(group)
	local unknown = { }
	for _, gem in ipairs(group.gemList) do
		if not gem.gemData then t_insert(unknown, gem.nameSpec) end
	end
	if args.main then
		build.mainSocketGroup = #skillsTab.socketGroupList
	end
	skillsTab:AddUndoState()
	markChanged(build)
	return { index = #skillsTab.socketGroupList, unknownGems = #unknown > 0 and unknown or nil }, true
end

commands.editSkillGroup = function(args)
	local build = requireBuild()
	local skillsTab = build.skillsTab
	local group = skillsTab.socketGroupList[tonumber(args.index) or -1] or error("No socket group at index " .. tostring(args.index), 0)
	if args.label ~= nil then group.label = args.label end
	if args.enabled ~= nil then group.enabled = args.enabled end
	if args.slot ~= nil then group.slot = args.slot ~= "" and args.slot or nil end
	if args.gems then
		group.gemList = { }
		for _, g in ipairs(args.gems) do t_insert(group.gemList, gemFromArg(g)) end
	end
	for _, change in ipairs(args.setGems or { }) do
		for _, gem in ipairs(group.gemList) do
			if lower(gem.nameSpec):gsub(" support$", "") == lower(change.name):gsub(" support$", "") then
				if change.level then gem.level = tonumber(change.level) end
				if change.quality then gem.quality = tonumber(change.quality) end
				if change.enabled ~= nil then gem.enabled = change.enabled end
			end
		end
	end
	skillsTab:ProcessSocketGroup(group)
	if skillsTab.displayGroup == group then skillsTab:SetDisplayGroup(group) end
	skillsTab:AddUndoState()
	markChanged(build)
	return { index = args.index }, true
end

commands.removeSkillGroup = function(args)
	local build = requireBuild()
	local skillsTab = build.skillsTab
	local index = tonumber(args.index) or -1
	if not skillsTab.socketGroupList[index] then error("No socket group at index " .. tostring(args.index), 0) end
	if skillsTab.displayGroup == skillsTab.socketGroupList[index] then skillsTab:SetDisplayGroup(nil) end
	table.remove(skillsTab.socketGroupList, index)
	if build.mainSocketGroup >= index and build.mainSocketGroup > 1 then
		build.mainSocketGroup = build.mainSocketGroup - 1
	end
	skillsTab:AddUndoState()
	markChanged(build)
	return { removed = index }, true
end

commands.setMainSkill = function(args)
	local build = requireBuild()
	local groups = build.skillsTab.socketGroupList
	local index = tonumber(args.index)
	if not index and args.name then
		for i, sg in ipairs(groups) do
			for _, skill in ipairs(sg.displaySkillList or { }) do
				if skill.activeEffect and lower(skill.activeEffect.grantedEffect.name) == lower(args.name) then
					index = i
					sg.mainActiveSkill = _
				end
			end
			if index then break end
		end
	end
	if not index or not groups[index] then error("Socket group / skill not found", 0) end
	build.mainSocketGroup = index
	if args.activeSkill then groups[index].mainActiveSkill = tonumber(args.activeSkill) end
	markChanged(build)
	return { mainSocketGroup = index }, true
end

-- Configuration ---------------------------------------------------------------

local configOptions = require("Modules.ConfigOptions")

commands.listConfig = function(args)
	local build = requireBuild()
	local input = build.configTab.configSets[build.configTab.activeConfigSetId].input
	local query = lower(args.query or "")
	local out = { }
	for _, varData in ipairs(configOptions) do
		if varData.var and (query == "" or lower(varData.var):find(query, 1, true) or lower(stripColors(varData.label)):find(query, 1, true)) then
			local entry = { var = varData.var, label = stripColors(varData.label), type = varData.type, value = input[varData.var], section = varData.section }
			if varData.list then
				entry.options = { }
				for _, opt in ipairs(varData.list) do t_insert(entry.options, opt.val) end
			end
			if args.changedOnly ~= true or input[varData.var] ~= nil then
				t_insert(out, entry)
			end
		end
	end
	return { options = out }
end

commands.setConfig = function(args)
	local build = requireBuild()
	local configTab = build.configTab
	local input = configTab.configSets[configTab.activeConfigSetId].input
	local values = args.values or { }
	if args.var then values[args.var] = args.value end
	local unset = args.unset or { }
	if next(values) == nil and #unset == 0 then error("Pass 'var' + 'value', 'values' or 'unset'", 0) end
	local function checkVar(var)
		for _, varData in ipairs(configOptions) do
			if varData.var == var then return varData end
		end
		error("Unknown config option '" .. tostring(var) .. "' (see listConfig)", 0)
	end
	for var, value in pairs(values) do
		checkVar(var)
		input[var] = value
	end
	for _, var in ipairs(unset) do
		checkVar(var)
		input[var] = nil
	end
	configTab:UpdateControls()
	configTab:AddUndoState()
	configTab:BuildModList()
	markChanged(build)
	return { set = values, unset = #unset > 0 and unset or nil }, true
end

-- UI --------------------------------------------------------------------------

local VIEW_MODES = { tree = "TREE", skills = "SKILLS", items = "ITEMS", calcs = "CALCS", config = "CONFIG", notes = "NOTES", party = "PARTY", import = "IMPORT" }

commands.setView = function(args)
	local build = requireBuild()
	local mode = VIEW_MODES[lower(args.tab)] or error("Unknown tab '" .. tostring(args.tab) .. "'", 0)
	build.viewMode = mode
	return { viewMode = mode }
end

commands.focusNode = function(args)
	local build = requireBuild()
	local node = findNode(build.spec, args.id or args.name, true)
	build.viewMode = "TREE"
	local treeTab = build.treeTab
	treeTab.jumpToNode = true
	treeTab.jumpToX = node.x
	treeTab.jumpToY = node.y
	if args.highlight ~= false then
		treeTab.controls.treeSearch:SetText(node.dn)
		treeTab.viewer.searchStr = node.dn
	end
	return { focused = node.dn, id = node.id }
end

commands.notes = function(args)
	local build = requireBuild()
	if args.text then
		build.notesTab.controls.edit:SetText(args.text)
		build.modFlag = true
	end
	return { notes = build.notesTab.controls.edit.buf }
end

---------------------------------------------------------------------------
-- Command queue
---------------------------------------------------------------------------

-- In-app activity toast so the user can see what an external tool is doing.
-- Disable with POB_BRIDGE_TOAST=0.
local TOAST_LINGER = 4000 -- ms
local toastId, toastHideAt
local showToasts = os.getenv("POB_BRIDGE_TOAST") ~= "0"

local function describeArgs(args)
	local parts = { }
	for _, key in ipairs({ "account", "character", "name", "id", "nodes", "add", "remove", "class", "ascendancy", "level", "tab", "var", "value", "values", "slot", "label", "query" }) do
		local v = args[key]
		if v ~= nil then
			if type(v) == "table" then
				local list = { }
				for k, x in pairs(v) do
					t_insert(list, type(k) == "number" and tostring(x) or (k .. "=" .. tostring(x)))
				end
				v = table.concat(list, ", ")
			end
			t_insert(parts, tostring(v))
		end
	end
	if args.gems then t_insert(parts, #args.gems .. " gems") end
	if args.text and not args.name then
		local first = args.text:match("Rarity:[^\n]*\n([^\n]+)") or args.text:match("^([^\n]+)")
		if first then t_insert(parts, first) end
	end
	local text = table.concat(parts, "  ")
	if #text > 70 then text = text:sub(1, 67) .. "..." end
	return text
end

local function formatChange(stat, d)
	local pct = d.percent and s_format(" (%+.1f%%)", d.percent) or ""
	local function num(x)
		local str = math.abs(x) >= 100 and s_format("%d", x + 0.5) or s_format("%.1f", x)
		return str:reverse():gsub("(%d%d%d)(%d)", "%1,%2"):reverse()
	end
	return s_format("%s %s -> %s%s", stat, num(d.before), num(d.after), pct)
end

local function showActivity(cmd, response)
	if not showToasts or not ToastNotification then return end
	local lines = { s_format("^7LiveBridge: ^x33FF77%s^7  %s", tostring(cmd.cmd), describeArgs(type(cmd.args) == "table" and cmd.args or { })) }
	if not response.ok then
		t_insert(lines, "^xFF5555" .. tostring(response.error))
	elseif response.diff or (response.result and response.result.diff) then
		local diff = response.diff or response.result.diff
		local shown = 0
		for _, stat in ipairs({ "FullDPS", "CombinedDPS", "Life", "EnergyShield", "TotalEHP", "FireResist", "ColdResist", "LightningResist", "ChaosResist" }) do
			if diff[stat] and shown < 3 then
				local prefix = response.diff and "^7" or "^7what-if: "
				t_insert(lines, prefix .. formatChange(stat, diff[stat]))
				shown = shown + 1
			end
		end
	end
	local message = table.concat(lines, "\n")
	if toastId and ToastNotification:Exists(toastId) then
		ToastNotification:Update(toastId, message)
	else
		toastId = ToastNotification:Add(message)
	end
	toastHideAt = GetTime() + TOAST_LINGER
end

local function updateToast()
	if toastId and toastHideAt and GetTime() > toastHideAt then
		if ToastNotification:Exists(toastId) then
			ToastNotification:Remove(toastId)
		end
		toastId, toastHideAt = nil, nil
	end
end

local function writeResponse(id, response)
	ensureDirs()
	writeFileAtomic(bridgeDir() .. "/responses/" .. id .. ".json", dkjson.encode(response, { indent = true }))
end

local function readNextCommand()
	local dir = bridgeDir() .. "/commands/"
	local names = { }
	local handle = NewFileSearch(dir .. "*.json")
	while handle do
		t_insert(names, handle:GetFileName())
		if not handle:NextFile() then break end
	end
	if #names == 0 then return end
	t_sort(names)
	local fileName = names[1]
	local f = io.open(dir .. fileName, "rb")
	if not f then return end
	local text = f:read("*a")
	f:close()
	os.remove(dir .. fileName)
	local fallbackId = fileName:gsub("%.json$", "")
	local cmd, _, err = dkjson.decode(text)
	if type(cmd) ~= "table" then
		return { id = fallbackId, parseError = "Invalid JSON: " .. tostring(err) }
	end
	cmd.id = tostring(cmd.id or fallbackId):gsub("[^%w%-_%.]", "_")
	return cmd
end

local function runCommand(cmd)
	if cmd.parseError then
		writeResponse(cmd.id, { id = cmd.id, ok = false, error = cmd.parseError })
		return
	end
	local handler = commands[cmd.cmd]
	if not handler then
		writeResponse(cmd.id, { id = cmd.id, cmd = cmd.cmd, ok = false, error = "Unknown command '" .. tostring(cmd.cmd) .. "' (try 'help')" })
		return
	end
	local ok, result, mutated, job = pcall(handler, type(cmd.args) == "table" and cmd.args or { })
	bridge.commandsProcessed = bridge.commandsProcessed + 1
	local response = { id = cmd.id, cmd = cmd.cmd, ok = ok }
	if ok and mutated == "async" then
		pending = { response = response, frames = 0, cmd = cmd, job = job }
		if showToasts and ToastNotification then
			showActivity(cmd, { ok = true })
			toastHideAt = nil -- keep it up until the job finishes
		end
		return
	end
	if ok then
		response.result = result
	else
		response.error = tostring(result)
		ConPrintf("LiveBridge: %s failed: %s", tostring(cmd.cmd), tostring(result))
	end
	if ok and mutated then
		local build = currentBuild()
		response.before = build and build.calcsTab and build.calcsTab.mainOutput and keyStats(build.calcsTab.mainOutput) or nil
		pending = { response = response, frames = 0, cmd = cmd }
	else
		writeResponse(cmd.id, response)
		if cmd.cmd ~= "ping" and cmd.cmd ~= "getState" and cmd.cmd ~= "getStats" then
			showActivity(cmd, response)
		end
	end
end

---------------------------------------------------------------------------
-- Background keep-alive
--
-- The SimpleGraphic runtime skips whole frames (OnFrame is never called) while the
-- window is unfocused, the cursor is not over it, and no Lua coroutine is suspended.
-- That would stall the command queue whenever PoB is behind another window.
-- Keeping one suspended coroutine alive makes the runtime keep calling OnFrame;
-- to avoid rendering at full speed in the background we then pace idle frames
-- ourselves with Sleep() while PoB is not the foreground window.
-- Set POB_BRIDGE_BACKGROUND=0 to turn this off.
---------------------------------------------------------------------------

local keepAlive -- strong reference: coroutine._list() only holds weak keys
local winApi    -- ffi.C with the few Win32 calls we need, or false when unavailable
local pidBuf

local function initBackground()
	if winApi ~= nil then return end
	winApi = false
	if os.getenv("POB_BRIDGE_BACKGROUND") == "0" then return end
	local okFfi, ffi = pcall(require, "ffi")
	if not okFfi or ffi.os ~= "Windows" then return end
	pcall(ffi.cdef, [[
		void Sleep(uint32_t ms);
		void* GetForegroundWindow(void);
		uint32_t GetWindowThreadProcessId(void* hwnd, uint32_t* pid);
		uint32_t GetCurrentProcessId(void);
	]])
	local okProbe = pcall(function()
		pidBuf = ffi.new("uint32_t[1]")
		local _ = ffi.C.GetCurrentProcessId() + 0
	end)
	if not okProbe then return end
	winApi = ffi.C
	keepAlive = coroutine.create(function()
		while true do coroutine.yield() end
	end)
	coroutine.resume(keepAlive)
end

local function isForeground()
	local hwnd = winApi.GetForegroundWindow()
	if hwnd == nil then return false end
	pidBuf[0] = 0
	winApi.GetWindowThreadProcessId(hwnd, pidBuf)
	return pidBuf[0] == winApi.GetCurrentProcessId()
end

local idle = true -- no command pending and the last queue scan found nothing
local lastActiveTime = 0 -- last time PoB was in the foreground or handled a command

local function paceBackgroundFrame()
	if not winApi then return end
	local now = GetTime()
	if pending or not idle or isForeground() then
		lastActiveTime = now
		return
	end
	winApi.Sleep(now - lastActiveTime > BACKGROUND_DEEP_AFTER and BACKGROUND_DEEP_FRAME_MS or BACKGROUND_FRAME_MS)
end

-- Called once per frame from main:OnFrame (after mode switches are applied)
function bridge:OnMainFrame()
	if not self.enabled then return end
	local okBg, errBg = pcall(function()
		initBackground()
		paceBackgroundFrame()
	end)
	if not okBg then
		winApi = false
		keepAlive = nil
		ConPrintf("LiveBridge background keep-alive disabled: %s", tostring(errBg))
	end
	local ok, err = pcall(function()
		ensureDirs()
		if pending and pending.job then
			local okJob, done, result = pcall(pending.job)
			if not okJob then
				local response = pending.response
				response.ok = false
				response.error = tostring(done)
				ConPrintf("LiveBridge: %s failed: %s", tostring(response.cmd), tostring(done))
				writeResponse(response.id, response)
				showActivity(pending.cmd, response)
				pending = nil
			elseif done then
				-- finished: answer like any other mutating command, once the build has settled
				pending.response.result = result
				pending.job = nil
				pending.frames = 0
			end
			return
		end
		if pending then
			pending.frames = pending.frames + 1
			-- wait for the recalculation that the command triggered
			if pending.frames < 2 or not buildIsSettled() then
				return
			end
			local response = pending.response
			local pendingCmd = pending.cmd
			pending = nil
			local build = currentBuild()
			if build then
				local after = keyStats(build.calcsTab.mainOutput)
				if response.before then
					response.diff = statDiff(response.before, after)
				end
				response.before = nil
				response.keyStats = after
				-- make sure build.xml / stats.json reflect the change before the client reads them
				lastExportBuild = nil
				lastExportTime = 0
				self:OnBuildFrame(build)
			end
			writeResponse(response.id, response)
			showActivity(pendingCmd, response)
			return
		end
		updateToast()
		local now = GetTime()
		if now - lastPollTime < POLL_INTERVAL then return end
		lastPollTime = now
		if not buildIsSettled() then return end
		local cmd = readNextCommand()
		idle = cmd == nil
		if cmd then
			runCommand(cmd)
		end
	end)
	if not ok then
		pending = nil
		ConPrintf("LiveBridge error: %s", tostring(err))
	end
end

bridge.commands = commands

-- Create the keep-alive coroutine while PoB is still initialising: the runtime only
-- guarantees 10 frames after boot, so when PoB starts behind another window waiting
-- for the first OnMainFrame could leave the bridge stalled forever.
if bridge.enabled then
	local okBg, errBg = pcall(initBackground)
	if not okBg then
		winApi = false
		ConPrintf("LiveBridge background keep-alive disabled: %s", tostring(errBg))
	end
end

return bridge
