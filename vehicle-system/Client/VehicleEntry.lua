local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer

local character
local humanoid
local root
local animator

local DEFAULT_WALKSPEED = 5
local DEFAULT_JUMPPOWER = 35
local DEFAULT_JUMPHEIGHT = 50
local DEFAULT_AUTOROTATE = true

local equippedToolBeforeEntry = nil
local isDriverSeat = false
local toolEquipBlocked = false
local transitionToolBlocker = nil
local passengerToolPhysicsConn = nil
local extendedBlockTimer = nil

local disabledCollisionParts = {}
local hiddenVisuals = {}

local fakeBody = nil
local entryTrack = nil
local exitTrack = nil

local currentToken = nil
local currentCar = nil
local currentSeat = nil
local currentDoorName = nil

local lastInteractionTime = 0
local INTERACTION_COOLDOWN = 0.5
local ENTRY_TRACK_COMPLETION_BUFFER = 0.35
local MIN_ENTRY_TRACK_WAIT = 2.5

local eventConnections = {}
local activePromptConnections = {}

local entrySessionId = 0
local finalizedEntryVisualSession = 0
local doorOpenedSent = false
local sequenceSent = false
local usingFakeBody = false

local STATES = {
	IDLE = "IDLE",
	ENTER_REQUESTED = "ENTER_REQUESTED",
	ENTER_ANIM = "ENTER_ANIM",
	DOOR_OPENED = "DOOR_OPENED",
	SEQUENCE_SENT = "SEQUENCE_SENT",
	SEATED = "SEATED",
	EXITING = "EXITING",
}

local fsm = {
	state = STATES.IDLE
}

function fsm:is(stateName)
	return self.state == stateName
end

function fsm:set(stateName)
	self.state = stateName
end

local function getEvent(name)
	local ev = ReplicatedStorage:FindFirstChild(name)
	if not ev then
		ev = ReplicatedStorage:WaitForChild(name, 10)
	end
	return ev
end

local EvBeginEntry = getEvent("VehicleBeginEntry")
local EvDoorOpen = getEvent("VehicleDoorOpen")
local EvSequenceComplete = getEvent("VehicleSequenceComplete")
local EvBeginExit = getEvent("VehicleBeginExit")
local EvExitComplete = getEvent("VehicleExitComplete")
local EvUpdateSeatedToken = getEvent("VehicleUpdateSeatedToken")
local EvPlayExitAnimation = getEvent("VehiclePlayExitAnimation")
local EvDisableEngine = getEvent("VehicleDisableEngine")
local EvEnableEngine = getEvent("VehicleEnableEngine")
local EvTogglePrompts = getEvent("VehicleTogglePrompts")
-- EvEntryAnimDone akan diambil saat diperlukan (lazy loading)
local EvEntryAnimDone = nil

local ANIM_IDS = {
	FL = "rbxassetid://140081428481519",
	RL = "rbxassetid://132526168877383",
	FR = "rbxassetid://95359500855321",
	RR = "rbxassetid://95359500855321",
}

-- Di client LocalScript, tambahkan ini
local DOOR_CFRAME_OFFSET = {
	FL = CFrame.Angles(0, math.rad(90), 0),
	FR = CFrame.identity,
	RL = CFrame.Angles(0, math.rad(90), 0),
	RR = CFrame.identity,
}

local EXIT_ANIM_IDS = {
	DriverSide = "rbxassetid://126551401428021",
	PassengerSide = "rbxassetid://92548300202889",
}

local isSeated = false
local isExiting = false
local exitBound = false
local inEntry = false

local currentVisibleLabel = nil

local function disconnectAll(list)
	for _, conn in ipairs(list) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(list)
end

local function stopEntryAnim()
	if entryTrack then
		pcall(function()
			if entryTrack.IsPlaying then
				entryTrack:Stop(0)
			end
		end)
	end
	entryTrack = nil
end

local function stopExitAnim()
	if exitTrack then
		pcall(function()
			if exitTrack.IsPlaying then
				exitTrack:Stop(0)
			end
		end)
	end
	exitTrack = nil
end

local function destroyFakeBody()
	if fakeBody then
		pcall(function()
			fakeBody:Destroy()
		end)
		fakeBody = nil
	end
end

local function disableCharacterCollision()
	disabledCollisionParts = {}
	if not character then return end

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			part.CanCollide = false
			table.insert(disabledCollisionParts, part)
		end
	end
end

local function restoreCharacterCollision()
	for _, part in ipairs(disabledCollisionParts) do
		if part and part.Parent then
			part.CanCollide = true
		end
	end
	disabledCollisionParts = {}
end

local function hideCharacterVisuals()
	hiddenVisuals = {}
	if not character then return end

	for _, obj in ipairs(character:GetDescendants()) do
		if obj:IsA("BasePart") then
			hiddenVisuals[obj] = {
				className = "BasePart",
				transparency = obj.Transparency,           -- simpan Transparency asli
			}
			obj.Transparency = 1                           -- ← ini yang bekerja
		elseif obj:IsA("Decal") or obj:IsA("Texture") then
			hiddenVisuals[obj] = {
				className = obj.ClassName,
				transparency = obj.Transparency,
			}
			obj.Transparency = 1
		end
	end
end

local function restoreCharacterVisuals()
	for obj, data in pairs(hiddenVisuals) do
		if obj and obj.Parent and data then
			obj.Transparency = data.transparency or 0     -- restore dari nilai asli
		end
	end
	hiddenVisuals = {}
end

local function restoreEntryVisualState()
	destroyFakeBody()
	restoreCharacterVisuals()
	restoreCharacterCollision()
end

local function createFakeBody(capturedCFrame)
	if not character or not character.Parent then return nil end

	local hum = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not hum or not rootPart then
		warn("createFakeBody: character belum lengkap")
		return nil
	end

	local oldArchivable = character.Archivable
	character.Archivable = true
	local ok, clone = pcall(function() return character:Clone() end)
	character.Archivable = oldArchivable

	if not ok or not clone then
		warn("createFakeBody: failed to clone character")
		return nil
	end

	local cloneHumanoid = clone:FindFirstChildOfClass("Humanoid")
	local cloneRoot = clone:FindFirstChild("HumanoidRootPart")
	if not cloneHumanoid or not cloneRoot then
		clone:Destroy()
		warn("createFakeBody: clone tidak lengkap")
		return nil
	end

	clone.Name = "FakeBody"

	for _, obj in ipairs(clone:GetDescendants()) do
		if obj:IsA("Script") or obj:IsA("LocalScript") then
			obj:Destroy()
		elseif obj:IsA("Tool") then
			obj:Destroy()
		elseif obj:IsA("BasePart") then
			obj.CanCollide = true
			obj.CanQuery = false
			obj.CanTouch = false
			obj.Massless = true
		end
	end

	cloneHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	cloneHumanoid.AutoRotate = false
	cloneHumanoid.WalkSpeed = 0
	cloneHumanoid.JumpPower = 0
	cloneHumanoid.JumpHeight = 0

	-- Anchor dulu sebelum PivotTo supaya physics tidak interferensi
	cloneRoot.Anchored = true
	clone.Parent = workspace

	-- Force clone ke posisi/orientasi character yang valid (sebelum server bisa reposisi)
	if capturedCFrame then
		clone.PrimaryPart = cloneRoot
		pcall(function()
			clone:PivotTo(capturedCFrame)
		end)
		-- Re-anchor karena PivotTo kadang un-anchor di Roblox
		cloneRoot.Anchored = true
	end

	return clone
end

local function moveFakeBodyToAttachment(fake, att, fallbackSeat, capturedCFrame)
	if not fake then return end

	local fakeRoot = fake:FindFirstChild("HumanoidRootPart")
	if not fakeRoot or not fakeRoot:IsA("BasePart") then return end

	local targetCFrame
	if att and att:IsA("Attachment") then
		targetCFrame = att.WorldCFrame
	elseif fallbackSeat and fallbackSeat:IsA("BasePart") then
		targetCFrame = fallbackSeat.CFrame
	elseif root then
		targetCFrame = root.CFrame
	else
		return
	end

	-- Gunakan capturedCFrame sebagai "from" yang reliable
	-- fakeRoot.CFrame seharusnya sudah = capturedCFrame dari createFakeBody
	-- tapi kita pakai capturedCFrame secara eksplisit untuk konsistensi
	local fromCFrame = capturedCFrame or fakeRoot.CFrame
	local delta = targetCFrame * fromCFrame:Inverse()

	for _, part in ipairs(fake:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CFrame = delta * part.CFrame
		end
	end

	fakeRoot.Anchored = true
end

local function bindExitKey()
	if exitBound then return end
	exitBound = true

	ContextActionService:BindAction(
		"VehicleExit",
		function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local currentTime = tick()
				if currentTime - lastInteractionTime < INTERACTION_COOLDOWN then
					return Enum.ContextActionResult.Sink
				end

				if not isSeated then return Enum.ContextActionResult.Sink end
				if isExiting then return Enum.ContextActionResult.Sink end
				if not humanoid or not humanoid.Parent then return Enum.ContextActionResult.Sink end
				if not humanoid.Sit then return Enum.ContextActionResult.Sink end
				if not currentToken or not currentSeat or not currentDoorName then
					return Enum.ContextActionResult.Sink
				end
				if not currentSeat.Parent then return Enum.ContextActionResult.Sink end

				lastInteractionTime = currentTime

				if character then
					local equippedTool = character:FindFirstChildOfClass("Tool")
					if equippedTool and humanoid then
						humanoid:UnequipTools()
					end
				end

				if EvBeginExit then
					EvBeginExit:FireServer(currentToken, currentSeat, currentDoorName)
				end
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.KeyCode.F
	)

	ContextActionService:BindAction(
		"BlockJump",
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.KeyCode.Space
	)
end

local function unbindExitKey()
	if not exitBound then return end
	exitBound = false
	pcall(function()
		ContextActionService:UnbindAction("VehicleExit")
		ContextActionService:UnbindAction("BlockJump")
	end)
end


local function playFakeBodyAnimation(fake, animId)
	if not fake then return nil end

	local fakeHumanoid = fake:FindFirstChildOfClass("Humanoid")
	if not fakeHumanoid then return nil end

	local fakeAnimator = fakeHumanoid:FindFirstChildOfClass("Animator")
	if not fakeAnimator then
		fakeAnimator = Instance.new("Animator")
		fakeAnimator.Parent = fakeHumanoid
	end

	local animObj = Instance.new("Animation")
	animObj.AnimationId = animId

	local track = fakeAnimator:LoadAnimation(animObj)
	animObj:Destroy()

	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	track:Play(0.1)

	return track
end

local function finalizeEntryVisuals(sessionId, shouldSignalAnimDone)
	if sessionId ~= entrySessionId then return end
	if finalizedEntryVisualSession == sessionId then return end

	finalizedEntryVisualSession = sessionId

	stopEntryAnim()
	restoreEntryVisualState()

	if shouldSignalAnimDone then
		if not EvEntryAnimDone then
			EvEntryAnimDone = getEvent("VehicleEntryAnimDone")
		end
		if EvEntryAnimDone and currentToken then
			EvEntryAnimDone:FireServer(currentToken)
		end
	end
end

local function blockToolEquip()
	if toolEquipBlocked then return end
	toolEquipBlocked = true

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)

	ContextActionService:BindAction(
		"BlockToolEquip",
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three,
		Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six,
		Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
		Enum.KeyCode.Zero
	)
end

local function unblockToolEquip()
	if not toolEquipBlocked then return end
	toolEquipBlocked = false

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
	end)

	pcall(function()
		ContextActionService:UnbindAction("BlockToolEquip")
	end)
end

local function blockTransitionToolEquip()
	if transitionToolBlocker then return end

	transitionToolBlocker = character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(function()
				if humanoid and humanoid.Parent then
					humanoid:UnequipTools()
				end
			end)
		end
	end)

	table.insert(eventConnections, transitionToolBlocker)
end

local function unblockTransitionToolEquip()
	if transitionToolBlocker then
		pcall(function()
			transitionToolBlocker:Disconnect()
		end)
		transitionToolBlocker = nil
	end

	if extendedBlockTimer then
		pcall(function()
			task.cancel(extendedBlockTimer)
		end)
		extendedBlockTimer = nil
	end
end

local function cleanupPassengerToolPhysics()
	if passengerToolPhysicsConn then
		pcall(function()
			passengerToolPhysicsConn:Disconnect()
		end)
		passengerToolPhysicsConn = nil
	end
end

local function startExtendedBlock(duration)
	if extendedBlockTimer then
		pcall(function()
			task.cancel(extendedBlockTimer)
		end)
	end

	blockTransitionToolEquip()

	extendedBlockTimer = task.delay(duration, function()
		unblockTransitionToolEquip()
		extendedBlockTimer = nil
	end)
end

local function forceUnblockAll()
	unblockTransitionToolEquip()
	cleanupPassengerToolPhysics()
	unblockToolEquip()
	unbindExitKey()
	restoreEntryVisualState()

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
	end)

	if humanoid and humanoid.Parent then
		humanoid.WalkSpeed = DEFAULT_WALKSPEED
		humanoid.JumpPower = DEFAULT_JUMPPOWER
		humanoid.JumpHeight = DEFAULT_JUMPHEIGHT
		humanoid.AutoRotate = DEFAULT_AUTOROTATE
	end
end

local function resetCharacterState()
	if not character or not character.Parent then return end

	stopEntryAnim()
	stopExitAnim()
	restoreEntryVisualState()
	cleanupPassengerToolPhysics()

	if humanoid and humanoid.Parent then
		humanoid.WalkSpeed = DEFAULT_WALKSPEED
		humanoid.JumpPower = DEFAULT_JUMPPOWER
		humanoid.JumpHeight = DEFAULT_JUMPHEIGHT
		humanoid.AutoRotate = DEFAULT_AUTOROTATE
		humanoid.PlatformStand = false
	end

	if root and root.Parent then
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part ~= root then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function unequipAllTools()
	if not character or not humanoid then return nil end

	local equippedTool = character:FindFirstChildOfClass("Tool")
	if equippedTool then
		humanoid:UnequipTools()
		return equippedTool
	end
	return nil
end

local function handlePassengerToolPhysics()
	if not character then return end

	cleanupPassengerToolPhysics()

	local toolAddedConn = character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			for _, part in ipairs(child:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Massless = true
					part.CanCollide = false
				end
			end
		end
	end)
	passengerToolPhysicsConn = toolAddedConn

	for _, tool in ipairs(character:GetChildren()) do
		if tool:IsA("Tool") then
			for _, part in ipairs(tool:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Massless = true
					part.CanCollide = false
				end
			end
		end
	end
end


local function connectSitHandler()
	if not humanoid then return end

	local conn = humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
		if humanoid.Sit then
			if not currentToken then
				return
			end

			if fsm:is(STATES.ENTER_ANIM) or fsm:is(STATES.DOOR_OPENED) or fsm:is(STATES.SEQUENCE_SENT) then
				fsm:set(STATES.SEATED)
			end

			inEntry = false
			isSeated = true

			-- Jangan restore collision di sini - tetap disabled selama di mobil
			-- Collision akan di-restore saat keluar dari mobil
			unblockTransitionToolEquip()

			-- Kirim sinyal ke server bahwa animasi entry sudah selesai
			-- Lazy load event jika belum ada
			if not EvEntryAnimDone then
				EvEntryAnimDone = getEvent("VehicleEntryAnimDone")
			end
			--if EvEntryAnimDone and currentToken then
			--	EvEntryAnimDone:FireServer(currentToken)
			--end

			if isDriverSeat then
				cleanupPassengerToolPhysics()
				blockToolEquip()
			else
				if character then
					handlePassengerToolPhysics()
				end
			end

			bindExitKey()
		else
			if isExiting then
				task.delay(1.5, function()
					isExiting = false
					forceUnblockAll()
				end)
				return
			end

			forceUnblockAll()
			isSeated = false
			isDriverSeat = false
			currentToken = nil
			currentSeat = nil
			currentDoorName = nil
			fsm:set(STATES.IDLE)

			resetCharacterState()

			if equippedToolBeforeEntry then
				task.wait(0.5)
				if character and character.Parent and humanoid and humanoid.Parent then
					humanoid:EquipTool(equippedToolBeforeEntry)
				end
				equippedToolBeforeEntry = nil
			end

			task.defer(function()
				currentCar = nil
			end)
		end
	end)

	table.insert(eventConnections, conn)
end





local function bindCharacter(char)
	disconnectAll(eventConnections)
	stopEntryAnim()
	stopExitAnim()
	unbindExitKey()
	unblockToolEquip()
	unblockTransitionToolEquip()
	cleanupPassengerToolPhysics()
	restoreEntryVisualState()

	disabledCollisionParts = {}
	hiddenVisuals = {}

	inEntry = false
	isSeated = false
	isExiting = false
	isDriverSeat = false
	equippedToolBeforeEntry = nil
	currentToken = nil
	currentCar = nil
	currentSeat = nil
	currentDoorName = nil

	fsm:set(STATES.IDLE)
	doorOpenedSent = false
	sequenceSent = false
	usingFakeBody = false
	finalizedEntryVisualSession = 0

	character = char
	humanoid = char:WaitForChild("Humanoid")
	root = char:WaitForChild("HumanoidRootPart")
	animator = humanoid:WaitForChild("Animator")

	local preloadedTracks = {}
	for _, id in pairs(ANIM_IDS) do
		local a = Instance.new("Animation")
		a.AnimationId = id
		local track = animator:LoadAnimation(a)
		table.insert(preloadedTracks, track)
		a:Destroy()
	end
	for _, id in pairs(EXIT_ANIM_IDS) do
		local a = Instance.new("Animation")
		a.AnimationId = id
		local track = animator:LoadAnimation(a)
		table.insert(preloadedTracks, track)
		a:Destroy()
	end

	task.spawn(function()
		task.wait(0.5)
		for _, track in ipairs(preloadedTracks) do
			if track then
				pcall(function()
					track:Stop()
				end)
			end
		end
	end)

	connectSitHandler()
end

local function trySendSequence(sessionId)
	if sessionId ~= entrySessionId then return end
	if sequenceSent then return end
	if not doorOpenedSent then return end
	if not currentToken then return end

	sequenceSent = true
	fsm:set(STATES.SEQUENCE_SENT)

	if EvSequenceComplete then
		EvSequenceComplete:FireServer(currentToken)
	end
end

local function startEntryVisual(animId, att, seat, capturedCFrame)
	destroyFakeBody()
	usingFakeBody = false

	local fake = createFakeBody(capturedCFrame) -- << pass ke sini
	if fake then
		usingFakeBody = true
		fakeBody = fake
		hideCharacterVisuals()
		moveFakeBodyToAttachment(fakeBody, att, seat, capturedCFrame) -- << dan ke sini
		entryTrack = playFakeBodyAnimation(fakeBody, animId)
	else
		--restoreCharacterVisuals()

		local animObj = Instance.new("Animation")
		animObj.AnimationId = animId
		local track = animator:LoadAnimation(animObj)
		animObj:Destroy()

		entryTrack = track
		track.Priority = Enum.AnimationPriority.Action4
		track.Looped = false
		track:Play(0.1)
	end

	return entryTrack
end

local function openDoorAndContinue(sessionId, doorName)
	if sessionId ~= entrySessionId then return end
	if doorOpenedSent then return end

	doorOpenedSent = true
	fsm:set(STATES.DOOR_OPENED)

	if EvDoorOpen and currentToken then
		EvDoorOpen:FireServer(currentToken, doorName)
	end

	trySendSequence(sessionId)
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(bindCharacter)

if EvUpdateSeatedToken then
	local conn = EvUpdateSeatedToken.OnClientEvent:Connect(function(newToken)
		currentToken = newToken
	end)
	table.insert(eventConnections, conn)
end

if EvBeginEntry then
	

	
	local conn = EvBeginEntry.OnClientEvent:Connect(function(token, doorName, att, driveSeat, seat)
		if inEntry then return end
		if not character or not character.Parent then return end
		if not humanoid or not humanoid.Parent then return end
		if not root or not root.Parent then return end
		if not animator or not animator.Parent then return end

		-- Hitung dari att langsung, identik dengan kalkulasi server
		-- Tidak bergantung pada root.CFrame yang replikasinya bisa telat
		local offset = DOOR_CFRAME_OFFSET[doorName] or CFrame.identity
		local capturedRootCFrame = att.WorldCFrame * offset

		fsm:set(STATES.ENTER_REQUESTED)

		equippedToolBeforeEntry = unequipAllTools()
		startExtendedBlock(2)

		inEntry = true
		isSeated = false
		sequenceSent = false
		doorOpenedSent = false

		currentToken = token
		currentCar = driveSeat and driveSeat.Parent
		currentSeat = seat
		currentDoorName = doorName
		isDriverSeat = (seat == driveSeat)

		stopEntryAnim()
		destroyFakeBody()

		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") and part ~= root then
				part.AssemblyLinearVelocity = Vector3.zero
				part.AssemblyAngularVelocity = Vector3.zero
			end
		end

		humanoid.AutoRotate = false
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0

		disableCharacterCollision()
		

		local animId = ANIM_IDS[doorName]
		if not animId then
			restoreCharacterCollision()
			inEntry = false
			fsm:set(STATES.IDLE)
			if EvSequenceComplete and currentToken then
				EvSequenceComplete:FireServer(currentToken)
			end
			return
		end

		entrySessionId += 1
		local sessionId = entrySessionId
		finalizedEntryVisualSession = 0

		fsm:set(STATES.ENTER_ANIM)

		-- Pass capturedRootCFrame ke startEntryVisual
		local track = startEntryVisual(animId, att, seat, capturedRootCFrame)
		if not track then
			restoreCharacterCollision()
			
			inEntry = false
			fsm:set(STATES.IDLE)
			if EvSequenceComplete and currentToken then
				EvSequenceComplete:FireServer(currentToken)
			end
			return
		end

		local doorMarkerFired = false

		local markerConn
		markerConn = track:GetMarkerReachedSignal("DoorOpen"):Connect(function()
			if sessionId ~= entrySessionId then return end
			if doorMarkerFired then return end
			doorMarkerFired = true
			pcall(function() markerConn:Disconnect() end)
			openDoorAndContinue(sessionId, doorName)
		end)

		local markerConn2
		markerConn2 = track:GetMarkerReachedSignal("IdleTime"):Connect(function()
			if sessionId ~= entrySessionId then return end
			pcall(function() markerConn2:Disconnect() end)
			finalizeEntryVisuals(sessionId, true)
		end)

		local trackLen = track.Length > 0 and track.Length or 2.0
		local fallbackT = math.max(trackLen * 0.3, 0.05)

		task.delay(fallbackT, function()
			if sessionId ~= entrySessionId then return end
			if not doorMarkerFired then
				doorMarkerFired = true
				pcall(function() markerConn:Disconnect() end)
				openDoorAndContinue(sessionId, doorName)
			end
		end)

		task.spawn(function()
			local stopped = false
			local stoppedConn
			stoppedConn = track.Stopped:Connect(function()
				stopped = true
				pcall(function() stoppedConn:Disconnect() end)
			end)

			-- Buffer accounts for playback timing variation, minimum wait gives short tracks time to settle.
			local maxWait = math.max(trackLen + ENTRY_TRACK_COMPLETION_BUFFER, MIN_ENTRY_TRACK_WAIT)
			local elapsed = 0
			while not stopped and elapsed < maxWait do
				task.wait(0.1)
				elapsed += 0.1
				if sessionId ~= entrySessionId then break end
			end

			if not stopped then
				pcall(function() stoppedConn:Disconnect() end)
			end

			if sessionId ~= entrySessionId then return end
			finalizeEntryVisuals(sessionId, true)
		end)

		task.spawn(function()
			local elapsed = 0
			while elapsed < 3 do
				task.wait(0.1)
				elapsed += 0.1
				if sessionId ~= entrySessionId then return end
				if sequenceSent then return end
			end

			if sessionId ~= entrySessionId then return end

			if not doorOpenedSent then
				openDoorAndContinue(sessionId, doorName)
			else
				trySendSequence(sessionId)
			end
		end)
	end)
	table.insert(eventConnections, conn)
end

if EvBeginExit then
	local conn = EvBeginExit.OnClientEvent:Connect(function(token)
		if not isSeated then return end
		if isExiting then return end

		stopExitAnim()
		startExtendedBlock(1.5)

		isExiting = true
		currentToken = token
		fsm:set(STATES.EXITING)

		unblockToolEquip()

		task.delay(1.5, function()
			if isExiting then
				isExiting = false
				forceUnblockAll()
				fsm:set(STATES.IDLE)
			end
		end)
	end)
	table.insert(eventConnections, conn)
end

if EvPlayExitAnimation then
	local conn = EvPlayExitAnimation.OnClientEvent:Connect(function(doorName, duration, startTime)
		if not character or not character.Parent then return end
		if not humanoid or not humanoid.Parent then return end
		if not animator or not animator.Parent then return end
		if not currentToken then return end

		if exitTrack and exitTrack.IsPlaying then
			pcall(function()
				exitTrack:Stop(0)
			end)
		end

		local isDriverSide = (doorName == "FL" or doorName == "RL")
		local animId = isDriverSide and EXIT_ANIM_IDS.DriverSide or EXIT_ANIM_IDS.PassengerSide

		local animObj = Instance.new("Animation")
		animObj.AnimationId = animId
		local track = animator:LoadAnimation(animObj)
		animObj:Destroy()

		exitTrack = track
		track.Priority = Enum.AnimationPriority.Action4
		track.Looped = false

		local doorCloseMarkerFired = false
		local doorCloseConn

		doorCloseConn = track:GetMarkerReachedSignal("DoorClose"):Connect(function()
			if doorCloseMarkerFired then return end
			doorCloseMarkerFired = true
			pcall(function()
				doorCloseConn:Disconnect()
			end)

			local EvDoorClose = getEvent("VehicleDoorClose")
			if EvDoorClose and currentToken then
				EvDoorClose:FireServer(currentToken, doorName)
			end
		end)

		track:Play(0)
		track:AdjustSpeed(1.5)
		track.TimePosition = startTime

		task.delay(duration, function()
			stopExitAnim()
		end)
	end)
	table.insert(eventConnections, conn)
end

if EvDisableEngine then
	local conn = EvDisableEngine.OnClientEvent:Connect(function()
		local acInterface = player.PlayerGui:FindFirstChild("A-Chassis Interface")
		if acInterface then
			local isOn = acInterface:FindFirstChild("IsOn")
			if isOn and isOn:IsA("BoolValue") then
				isOn.Value = false
			end
		end
	end)
	table.insert(eventConnections, conn)
end

if EvEnableEngine then
	local conn = EvEnableEngine.OnClientEvent:Connect(function()
		local acInterface = player.PlayerGui:FindFirstChild("A-Chassis Interface")
		if acInterface then
			local isOn = acInterface:FindFirstChild("IsOn")
			if isOn and isOn:IsA("BoolValue") then
				isOn.Value = true
			end
		end
	end)
	table.insert(eventConnections, conn)
end

if EvTogglePrompts then
	local conn = EvTogglePrompts.OnClientEvent:Connect(function(car, enabled)
		if not car or not car.Parent then return end

		task.wait(0.1)

		if not car or not car.Parent then return end

		for _, desc in ipairs(car:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				desc.Enabled = enabled
			end
		end
	end)
	table.insert(eventConnections, conn)
end

local PlayerGui = player:WaitForChild("PlayerGui")
local PromptScreen = PlayerGui:FindFirstChild("PromptScreen")
if not PromptScreen then return end

local PromptFrame = PromptScreen:FindFirstChild("PromptFrame")
if not PromptFrame then return end

local DriveLabel = PromptFrame:FindFirstChild("Drive")
local PassenLabel = PromptFrame:FindFirstChild("Passen")
if not DriveLabel or not PassenLabel then return end

DriveLabel.Visible = false
PassenLabel.Visible = false

local function getSeatType(seat)
	if not seat or not seat.Parent then return nil end
	local car = seat.Parent
	if not car or not car.Parent then return nil end
	local driveSeat = car:FindFirstChild("DriveSeat")
	if seat == driveSeat or seat.Name == "FL" then
		return "Drive"
	elseif seat.Name == "FR" or seat.Name == "RL" or seat.Name == "RR" then
		return "Passen"
	end
	return nil
end

local function showLabel(labelType)
	if currentVisibleLabel then
		currentVisibleLabel.Visible = false
	end

	if labelType == "Drive" then
		DriveLabel.Visible = true
		currentVisibleLabel = DriveLabel
	elseif labelType == "Passen" then
		PassenLabel.Visible = true
		currentVisibleLabel = PassenLabel
	end
end

local function hideLabel()
	if currentVisibleLabel then
		currentVisibleLabel.Visible = false
		currentVisibleLabel = nil
	end
end

local function disconnectPrompt(prompt)
	if activePromptConnections[prompt] then
		for _, conn in ipairs(activePromptConnections[prompt]) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		activePromptConnections[prompt] = nil
	end
end

local function connectPrompt(prompt)
	if not prompt or not prompt.Parent then return end
	if prompt.Name ~= "VehicleEntry" then return end

	disconnectPrompt(prompt)

	local attachment = prompt.Parent
	if not attachment or not attachment:IsA("Attachment") then return end

	local function findSeat()
		if not attachment or not attachment.Parent then return nil end
		if attachment.Name == "PromptPosition" then
			local parent = attachment.Parent
			if parent and (parent:IsA("Seat") or parent:IsA("VehicleSeat")) then
				return parent
			end
		end
		return nil
	end

	local connections = {}

	local shownConn = prompt.PromptShown:Connect(function()
		if isSeated then return end
		local seat = findSeat()
		if not seat or not seat.Parent then return end
		if seat.Occupant then return end
		local seatType = getSeatType(seat)
		if seatType then
			showLabel(seatType)
		end
	end)

	local hiddenConn = prompt.PromptHidden:Connect(function()
		hideLabel()
	end)

	local ancestryConn = prompt.AncestryChanged:Connect(function()
		if not prompt.Parent then
			disconnectPrompt(prompt)
			hideLabel()
		end
	end)

	table.insert(connections, shownConn)
	table.insert(connections, hiddenConn)
	table.insert(connections, ancestryConn)

	table.insert(eventConnections, shownConn)
	table.insert(eventConnections, hiddenConn)
	table.insert(eventConnections, ancestryConn)

	activePromptConnections[prompt] = connections
end

for _, descendant in ipairs(workspace:GetDescendants()) do
	if descendant:IsA("ProximityPrompt") then
		task.spawn(function()
			connectPrompt(descendant)
		end)
	end
end

local workspaceConn = workspace.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("ProximityPrompt") then
		task.spawn(function()
			task.wait(0.1)
			connectPrompt(descendant)
		end)
	end
end)
table.insert(eventConnections, workspaceConn)

local workspaceRemovingConn = workspace.DescendantRemoving:Connect(function(descendant)
	if descendant:IsA("ProximityPrompt") then
		disconnectPrompt(descendant)
	end
end)
table.insert(eventConnections, workspaceRemovingConn)
