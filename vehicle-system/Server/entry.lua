local EnterHandler = {}
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local PLAYER_CGROUP = "Characters"
local CAR_CGROUP = "CarBody"
local TRANSITION_CGROUP = "Transitioning"

pcall(function() PhysicsService:RegisterCollisionGroup(PLAYER_CGROUP) end)
pcall(function() PhysicsService:RegisterCollisionGroup(CAR_CGROUP) end)
pcall(function() PhysicsService:RegisterCollisionGroup(TRANSITION_CGROUP) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable(PLAYER_CGROUP, CAR_CGROUP, true) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable("Default", CAR_CGROUP, true) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable(TRANSITION_CGROUP, CAR_CGROUP, false) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable(TRANSITION_CGROUP, TRANSITION_CGROUP, false) end)

local EVENT_NAMES = {
	"VehicleBeginEntry",
	"VehicleDoorOpen",
	"VehicleSequenceComplete",
	"VehicleClientDoorOpen",
	"VehicleBeginExit",
	"VehicleExitComplete",
	"VehicleUpdateSeatedToken",
	"VehiclePlayExitAnimation",
	"VehicleDoorClose",
	"ToggleLock",
	"FlipCar",
	"VehicleTogglePrompts",
	"VehicleDisableEngine",
	"VehicleEnableEngine",
	"VehicleEntryAnimDone",
}

local events = {}
for _, name in EVENT_NAMES do
	local ev = ReplicatedStorage:FindFirstChild(name)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = name
		ev.Parent = ReplicatedStorage
	end
	events[name] = ev
end

local STATE = {
	ENTERING = "ENTERING",
	SEATED = "SEATED",
	EXITING = "EXITING",
}

local MAX_ENTRY_TIME = 4.0
local DOOR_SIGNAL_TIMEOUT = 2.0
local SEAT_WELD_TIMEOUT = 3.0
local MAX_PROMPT_DISTANCE = 10
local ENTRY_COOLDOWN = 1.0
local EXIT_COOLDOWN = 0.75
local LOCK_TOGGLE_COOLDOWN = 0.5
local VALID_DOORS = { FL = true, FR = true, RL = true, RR = true }

local DOOR_CFRAME_OFFSET = {
	FL = CFrame.Angles(0, math.rad(180), 0),
	FR = CFrame.identity,
	RL = CFrame.Angles(0, math.rad(180), 0),
	RR = CFrame.identity,
}

local PlayerState = {}
local busySeats = {}
local lastEntryAttempt = {}
local lastExitAttempt = {}
local lastLockToggle = {}
local _globalInit = false

local function cacheCharacterParts(char)
	local parts = {}
	for _, part in char:GetDescendants() do
		if part:IsA("BasePart") then
			table.insert(parts, part)
		end
	end
	return parts
end

local function setPartsCollisionGroup(parts, group)
	for _, part in parts do
		if part and part.Parent then
			pcall(function() part.CollisionGroup = group end)
		end
	end
end

local function setPartsMassless(parts, massless)
	for _, part in parts do
		if part and part.Parent then
			pcall(function() part.Massless = massless end)
		end
	end
end

local function setPartsCanCollide(parts, canCollide)
	for _, part in parts do
		if part and part.Parent then
			pcall(function() part.CanCollide = canCollide end)
		end
	end
end

local function findDoorAttachment(car, doorName)
	local ds = car:FindFirstChild("DriveSeat")
	if not ds then return nil end
	local positions = ds:FindFirstChild("Positions")
	if positions then
		return positions:FindFirstChild(doorName)
	end
	return nil
end

local function disconnectAll(connections)
	if not connections then return end
	for _, conn in connections do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(connections)
end

local function cleanupPlayer(player)
	local data = PlayerState[player]
	if not data then return end

	if data.seat then
		busySeats[data.seat] = nil
	end

	if data.positionTween then
		pcall(function() data.positionTween:Cancel() end)
		data.positionTween = nil
	end

	PlayerState[player] = nil
	disconnectAll(data.connections)

	local char = player.Character
	if not char or not char.Parent then return end
	if not data.cachedParts then return end

	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")

	if hum and hum.Parent then
		hum.WalkSpeed = 5
		hum.JumpPower = 35
		hum.JumpHeight = 50
		hum.AutoRotate = true
		hum.PlatformStand = false
	end

	if hrp and hrp.Parent then
		hrp.Anchored = false
	end

	setPartsCanCollide(data.cachedParts, true)
	setPartsMassless(data.cachedParts, false)
	setPartsCollisionGroup(data.cachedParts, PLAYER_CGROUP)

	if data.car and data.car.Parent then
		events.VehicleTogglePrompts:FireClient(player, data.car, true)
	end

	char:SetAttribute("IsTransitioning", nil)
end

local function isAlive(player)
	local char = player.Character
	if not char or not char.Parent then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum and hum.Parent and hum.Health > 0
end

local function waitForClientSignal(player, event, timeout)
	local data = PlayerState[player]
	if not data then return nil end
	if data.state ~= STATE.ENTERING and data.state ~= STATE.EXITING then return nil end

	local expectedToken = data.token
	local bindable = Instance.new("BindableEvent")
	local resolved = false
	local conn

	conn = event.OnServerEvent:Connect(function(sender, receivedToken, ...)
		if resolved then return end
		if sender ~= player then return end
		if receivedToken ~= expectedToken then return end

		local pData = PlayerState[sender]
		if not pData then return end
		if pData.state ~= STATE.ENTERING and pData.state ~= STATE.EXITING then return end
		if pData.token ~= expectedToken then return end

		resolved = true
		pcall(function() conn:Disconnect() end)
		bindable:Fire(true, ...)
	end)

	task.delay(timeout, function()
		if not resolved then
			resolved = true
			pcall(function() conn:Disconnect() end)
			bindable:Fire(nil)
		end
	end)

	local result = { bindable.Event:Wait() }
	bindable:Destroy()
	return table.unpack(result)
end

-- Fungsi khusus untuk menunggu VehicleEntryAnimDone (state bisa SEATED)
local function waitForAnimDoneSignal(player, event, timeout)
	local data = PlayerState[player]
	if not data then return nil end

	local expectedToken = data.token
	local bindable = Instance.new("BindableEvent")
	local resolved = false
	local conn

	conn = event.OnServerEvent:Connect(function(sender, receivedToken, ...)
		if resolved then return end
		if sender ~= player then return end
		if receivedToken ~= expectedToken then return end

		local pData = PlayerState[sender]
		if not pData then return end
		if pData.token ~= expectedToken then return end

		resolved = true
		pcall(function() conn:Disconnect() end)
		bindable:Fire(true, ...)
	end)

	task.delay(timeout, function()
		if not resolved then
			resolved = true
			pcall(function() conn:Disconnect() end)
			bindable:Fire(nil)
		end
	end)

	local result = { bindable.Event:Wait() }
	bindable:Destroy()
	return table.unpack(result)
end

function EnterHandler:IsPlayerInState(player)
	local data = PlayerState[player]
	if not data then return nil end
	return data.state
end

function EnterHandler:Enter(player, seat, car, doorStateMap, doorHandler, doorName)
	if PlayerState[player] then return end
	if busySeats[seat] then return end
	if not VALID_DOORS[doorName] then return end

	if lastEntryAttempt[player] and os.clock() - lastEntryAttempt[player] < ENTRY_COOLDOWN then
		return
	end
	lastEntryAttempt[player] = os.clock()

	local char = player.Character
	if not char or not char.Parent then return end
	if char:GetAttribute("IsTransitioning") then return end

	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not hrp or hum.Sit then return end
	if seat.Occupant then return end

	local staleSeatWeld = seat:FindFirstChild("SeatWeld")
	if staleSeatWeld then
		staleSeatWeld:Destroy()
	end

	local wheelsFolder = car:FindFirstChild("Wheels")
	if wheelsFolder then
		for _, wheel in wheelsFolder:GetChildren() do
			if wheel:IsA("BasePart") then
				local av = wheel:FindFirstChild("#AV")
				if av and av:IsA("HingeConstraint") then
					if av.MotorMaxTorque ~= 0 or av.AngularVelocity ~= 0 then
						av.MotorMaxTorque = 0
						av.AngularVelocity = 0
					end
				end

				local bv = wheel:FindFirstChild("#BV")
				if bv and bv:IsA("HingeConstraint") then
					if bv.AngularVelocity ~= 0 then
						bv.AngularVelocity = 0
					end
				end
			end
		end
	end

	local att = findDoorAttachment(car, doorName)
	local driveSeat = car:FindFirstChild("DriveSeat")
	if not att or not driveSeat then return end

	if (hrp.Position - att.WorldPosition).Magnitude > MAX_PROMPT_DISTANCE then return end

	local token = HttpService:GenerateGUID(false)
	local cachedParts = cacheCharacterParts(char)

	char:SetAttribute("IsTransitioning", true)

	PlayerState[player] = {
		state = STATE.ENTERING,
		seat = seat,
		car = car,
		token = token,
		startTime = os.clock(),
		doorName = doorName,
		connections = {},
		cachedParts = cachedParts,
		doorStateMap = doorStateMap,
		doorHandler = doorHandler,
		positionTween = nil,
	}
	busySeats[seat] = player

	table.insert(PlayerState[player].connections, hum.Died:Connect(function()
		cleanupPlayer(player)
	end))

	table.insert(PlayerState[player].connections, char.AncestryChanged:Connect(function()
		if not char.Parent then cleanupPlayer(player) end
	end))

	table.insert(PlayerState[player].connections, seat.AncestryChanged:Connect(function()
		if not seat.Parent then cleanupPlayer(player) end
	end))

	table.insert(PlayerState[player].connections, car.AncestryChanged:Connect(function()
		if not car.Parent then cleanupPlayer(player) end
	end))

	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.JumpHeight = 0
	hum.AutoRotate = false

	setPartsCollisionGroup(cachedParts, TRANSITION_CGROUP)
	setPartsMassless(cachedParts, true)

	local offset = DOOR_CFRAME_OFFSET[doorName] or CFrame.identity
	hrp.CFrame = att.WorldCFrame * offset
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero

	events.VehicleTogglePrompts:FireClient(player, car, false)

	events.VehicleBeginEntry:FireClient(player, token, doorName, att, driveSeat, seat)

	local doorSignal = waitForClientSignal(player, events.VehicleDoorOpen, DOOR_SIGNAL_TIMEOUT)

	if not PlayerState[player] or PlayerState[player].state ~= STATE.ENTERING then
		cleanupPlayer(player)
		return
	end
	if not isAlive(player) then
		cleanupPlayer(player)
		return
	end

	for _, p in Players:GetPlayers() do
		if p ~= player then
			events.VehicleClientDoorOpen:FireClient(p, doorName, car)
		end
	end
	if doorStateMap and doorStateMap[doorName] then
		doorHandler:OpenDoor(doorStateMap[doorName])
	end

	local remaining = MAX_ENTRY_TIME - (os.clock() - PlayerState[player].startTime)
	if remaining <= 0 then
		cleanupPlayer(player)
		return
	end

	local seqSignal = waitForClientSignal(player, events.VehicleSequenceComplete, remaining)

	if not PlayerState[player] or PlayerState[player].state ~= STATE.ENTERING then
		cleanupPlayer(player)
		return
	end
	if not isAlive(player) then
		cleanupPlayer(player)
		return
	end
	if not seqSignal then
		cleanupPlayer(player)
		return
	end
	if not seat.Parent or seat.Occupant then
		cleanupPlayer(player)
		return
	end
	if not char.Parent or not hrp.Parent or not hum.Parent then
		cleanupPlayer(player)
		return
	end

	local currentState = PlayerState[player]
	if not currentState or currentState.state ~= STATE.ENTERING then
		cleanupPlayer(player)
		return
	end

	if currentState.positionTween then
		pcall(function() currentState.positionTween:Cancel() end)
		currentState.positionTween = nil
	end

	for _, part in cachedParts do
		if part and part.Parent then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end

	hrp.Anchored = true

	setPartsCanCollide(cachedParts, false)

	if not char.Parent or not hrp.Parent or not hum.Parent then
		if hrp and hrp.Parent then
			hrp.Anchored = false
		end
		cleanupPlayer(player)
		return
	end

	if seat.Disabled then
		seat.Disabled = false
	end

	if not seat or not seat.Parent then
		if hrp and hrp.Parent then
			hrp.Anchored = false
		end
		cleanupPlayer(player)
		return
	end

	seat:Sit(hum)

	-- FIX: Wait for SeatWeld sebelum un-anchoring
	-- Ini mencegah karakter jatuh jika SeatWeld belum terbentuk
	local seatWeldStart = os.clock()
	local seatWeld = nil
	while not seatWeld and (os.clock() - seatWeldStart) < SEAT_WELD_TIMEOUT do
		seatWeld = seat:FindFirstChild("SeatWeld")
		if not seatWeld then task.wait() end
	end

	-- Un-anchor setelah SeatWeld dikonfirmasi
	hrp.Anchored = false

	if not seat or not seat.Parent then
		cleanupPlayer(player)
		return
	end

	currentState = PlayerState[player]
	if not currentState or currentState.state ~= STATE.ENTERING then
		cleanupPlayer(player)
		return
	end

	if not seatWeld then
		if hrp and hrp.Parent then
			hrp.Anchored = false
		end
		cleanupPlayer(player)
		return
	end

	if not char.Parent or not hrp.Parent or not hum.Parent then
		if hrp and hrp.Parent then
			hrp.Anchored = false
		end
		cleanupPlayer(player)
		return
	end

	-- Jangan restore collision di sini - tetap disabled selama di mobil
	-- Collision akan di-restore saat keluar dari mobil
	-- setPartsCollisionGroup(cachedParts, PLAYER_CGROUP)
	-- setPartsCanCollide(cachedParts, true)

	currentState = PlayerState[player]
	if currentState then
		if currentState.connections then
			disconnectAll(currentState.connections)
		end
		currentState.state = STATE.SEATED
		currentState.connections = {}
	end

	char:SetAttribute("IsTransitioning", nil)

	-- Tunggu sinyal dari client bahwa animasi entry sudah selesai
	local animDoneSignal = waitForAnimDoneSignal(player, events.VehicleEntryAnimDone, 3.0)

	if PlayerState[player] and PlayerState[player].state == STATE.SEATED then
		if doorStateMap and doorStateMap[doorName] then
			doorHandler:CloseDoor(doorStateMap[doorName], 0.1)
		end
	end
end

function EnterHandler:Exit(seat, doorStateMap, doorHandler, doorName, player, char)
	local cachedParts = nil

	if player and PlayerState[player] then
		local data = PlayerState[player]
		if data.state == STATE.EXITING then return end

		if data.seat then
			busySeats[data.seat] = nil
		end

		cachedParts = data.cachedParts

		PlayerState[player] = nil
		disconnectAll(data.connections)

		if cachedParts then
			setPartsMassless(cachedParts, false)
			setPartsCanCollide(cachedParts, true)
			setPartsCollisionGroup(cachedParts, PLAYER_CGROUP)
		end
	end

	if char and char.Parent then
		if not cachedParts then
			cachedParts = cacheCharacterParts(char)
		end

		if cachedParts then
			setPartsMassless(cachedParts, false)
			setPartsCanCollide(cachedParts, true)
			setPartsCollisionGroup(cachedParts, PLAYER_CGROUP)
		end

		local hrp = char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp.Parent then
			hrp.Anchored = false
		end

		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Parent then
			hum.WalkSpeed = 5
			hum.JumpPower = 35
			hum.JumpHeight = 50
			hum.AutoRotate = true
			hum.PlatformStand = false
			task.wait()
			hum:ChangeState(Enum.HumanoidStateType.Running)
		end

		char:SetAttribute("IsTransitioning", nil)
	end

	local doorState = doorStateMap and doorStateMap[doorName]
	if doorState then
		pcall(function() doorHandler:OpenDoor(doorState) end)
		task.wait(0.4)
		pcall(function() doorHandler:CloseDoor(doorState, 0.5) end)
	end
end

function EnterHandler:InitGlobalHandlers()
	if _globalInit then return end
	_globalInit = true

	local function assignPlayerCollisionGroup(character)
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.CollisionGroup = PLAYER_CGROUP
				part.CanCollide = true
			end
		end
		character.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				descendant.CollisionGroup = PLAYER_CGROUP
				descendant.CanCollide = true
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			assignPlayerCollisionGroup(player.Character)
		end
		player.CharacterAdded:Connect(assignPlayerCollisionGroup)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(assignPlayerCollisionGroup)
	end)

	local FLIP_COOLDOWN = 5
	local lastFlip = {}

	events.VehicleBeginExit.OnServerEvent:Connect(function(player, receivedToken, seat, doorName)
		local data = PlayerState[player]
		if not data then return end
		if data.state ~= STATE.SEATED then return end
		if data.token ~= receivedToken then return end
		if not VALID_DOORS[doorName] then return end

		local now = os.clock()
		if lastExitAttempt[player] and (now - lastExitAttempt[player]) < EXIT_COOLDOWN then return end
		lastExitAttempt[player] = now

		local char = player.Character
		if not char or not char.Parent then return end
		if char:GetAttribute("IsTransitioning") then return end

		local hum = char:FindFirstChildOfClass("Humanoid")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		local animator = hum and hum:FindFirstChild("Animator")
		if not hum or not hum.Sit or not hrp or not animator then return end
		if not seat or not seat.Parent then return end

		local car = data.car
		if not car or not car.Parent then return end

		local exitAtt = findDoorAttachment(car, doorName)
		if not exitAtt then return end

		char:SetAttribute("IsTransitioning", true)

		data.state = STATE.EXITING
		local exitToken = HttpService:GenerateGUID(false)
		data.token = exitToken
		data.exitDoorName = doorName

		events.VehicleTogglePrompts:FireClient(player, car, false)

		local isDriveSeat = (data.seat == car.DriveSeat)

		if isDriveSeat then
			events.VehicleDisableEngine:FireClient(player)

			local wheelsFolder = car:FindFirstChild("Wheels")
			if wheelsFolder then
				for _, wheel in wheelsFolder:GetChildren() do
					if wheel:IsA("BasePart") then
						local av = wheel:FindFirstChild("#AV")
						if av and av:IsA("HingeConstraint") then
							av.MotorMaxTorque = 0
							av.AngularVelocity = 0
						end

						local bv = wheel:FindFirstChild("#BV")
						if bv and bv:IsA("HingeConstraint") then
							bv.MotorMaxTorque = 0
							bv.AngularVelocity = 0
						end
					end
				end
			end

			local brakeStartTime = os.clock()
			local SPEED_THRESHOLD = 5
			local BRAKE_TIMEOUT = 5

			while true do
				local elapsed = os.clock() - brakeStartTime

				if not PlayerState[player] or not car.Parent or not char.Parent then
					return
				end

				local velocity = car.DriveSeat.AssemblyLinearVelocity.Magnitude

				if velocity < SPEED_THRESHOLD or elapsed >= BRAKE_TIMEOUT then
					break
				end

				task.wait(0.1)
			end
		end

		events.VehicleBeginExit:FireClient(player, exitToken)

		task.wait(0.1)

		hum.PlatformStand = true

		for _, part in data.cachedParts do
			if part and part.Parent then
				part.Massless = true
			end
		end

		setPartsCollisionGroup(data.cachedParts, TRANSITION_CGROUP)

		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero

		local seatWeld = seat:FindFirstChild("SeatWeld")
		if seatWeld then
			seatWeld:Destroy()
		end

		hrp.Anchored = true

		local startTime = 1.14

		local animLength = 2.5
		local duration = (animLength - startTime) / 1.5

		events.VehiclePlayExitAnimation:FireClient(player, doorName, duration, startTime)

		local doorStateMap = data.doorStateMap
		local doorHandler = data.doorHandler
		if doorStateMap and doorStateMap[doorName] and doorHandler then
			doorHandler:OpenDoor(doorStateMap[doorName])
		end

		local doorOffset = DOOR_CFRAME_OFFSET[doorName] or CFrame.identity
		local targetCFrame = exitAtt.WorldCFrame * doorOffset

		local tween = TweenService:Create(
			hrp,
			TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = targetCFrame }
		)

		tween:Play()

		local exitActive = true

		local cleanupConnection
		cleanupConnection = tween.Completed:Connect(function()
			if not exitActive then return end
			exitActive = false

			pcall(function() cleanupConnection:Disconnect() end)

			if not PlayerState[player] or PlayerState[player].state ~= STATE.EXITING then
				if char and char.Parent then
					char:SetAttribute("IsTransitioning", nil)
				end
				return
			end

			if not char.Parent or not hum.Parent or not hrp.Parent then
				cleanupPlayer(player)
				return
			end

			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero

			for _, part in data.cachedParts do
				if part and part.Parent then
					part.AssemblyLinearVelocity = Vector3.zero
					part.AssemblyAngularVelocity = Vector3.zero
				end
			end

			hum.PlatformStand = false

			task.wait(0.1)

			if not char.Parent or not hum.Parent or not hrp.Parent then
				cleanupPlayer(player)
				return
			end

			hrp.Anchored = false

			task.wait()

			if hum and hum.Parent then
				hum:ChangeState(Enum.HumanoidStateType.Running)
			end

			for _, part in data.cachedParts do
				if part and part.Parent then
					part.Massless = false
				end
			end

			if hum and hum.Parent then
				hum.WalkSpeed = 5
				hum.JumpPower = 35
				hum.JumpHeight = 50
				hum.AutoRotate = true
			end

			if data.seat then
				busySeats[data.seat] = nil
			end

			PlayerState[player] = nil
			disconnectAll(data.connections)

			events.VehicleTogglePrompts:FireClient(player, car, true)

			setPartsCanCollide(data.cachedParts, true)
			setPartsMassless(data.cachedParts, false)
			setPartsCollisionGroup(data.cachedParts, PLAYER_CGROUP)

			if char and char.Parent then
				char:SetAttribute("IsTransitioning", nil)
			end
		end)

		table.insert(data.connections, char.AncestryChanged:Connect(function()
			if not char.Parent and exitActive then
				exitActive = false
				if tween then tween:Cancel() end
				cleanupPlayer(player)
			end
		end))

		table.insert(data.connections, car.AncestryChanged:Connect(function()
			if not car.Parent and exitActive then
				exitActive = false
				if tween then tween:Cancel() end
				cleanupPlayer(player)
			end
		end))

		table.insert(data.connections, hum.Died:Connect(function()
			if exitActive then
				exitActive = false
				if tween then tween:Cancel() end
				cleanupPlayer(player)
			end
		end))
	end)

	events.VehicleExitComplete.OnServerEvent:Connect(function(player, receivedToken)
		local data = PlayerState[player]
		if not data then return end
		if data.state ~= STATE.EXITING then return end
		if data.token ~= receivedToken then return end
	end)

	events.VehicleDoorClose.OnServerEvent:Connect(function(player, receivedToken, doorName)
		local data = PlayerState[player]
		if not data then return end
		if data.state ~= STATE.EXITING then return end
		if data.token ~= receivedToken then return end

		local doorStateMap = data.doorStateMap
		local doorHandler = data.doorHandler
		if doorStateMap and doorStateMap[doorName] and doorHandler then
			doorHandler:CloseDoor(doorStateMap[doorName], 0)
		end
	end)

	events.ToggleLock.OnServerEvent:Connect(function(player, car)
		if typeof(car) ~= "Instance" or not car:IsA("Model") then return end

		local now = os.clock()
		if lastLockToggle[player] and (now - lastLockToggle[player]) < LOCK_TOGGLE_COOLDOWN then return end
		lastLockToggle[player] = now

		local ownerVal = car:FindFirstChild("Owner")
		if ownerVal then
			if string.lower(tostring(ownerVal.Value)) ~= string.lower(player.Name) then return end
		end

		local locked = car:FindFirstChild("Locked")
		if locked and locked:IsA("BoolValue") then
			locked.Value = not locked.Value

			for _, player in Players:GetPlayers() do
				local isOwner = ownerVal and string.lower(tostring(ownerVal.Value)) == string.lower(player.Name)

				for _, desc in car:GetDescendants() do
					if desc:IsA("ProximityPrompt") and desc.Name == "VehicleEntry" then
						if locked.Value then
							if isOwner then
								desc.Enabled = true
							else
								desc.Enabled = false
							end
						else
							desc.Enabled = true
						end
					end
				end
			end
		end
	end)

	events.FlipCar.OnServerEvent:Connect(function(player, car)
		if typeof(car) ~= "Instance" or not car:IsA("Model") then return end

		local uid = player.UserId
		local now = os.clock()

		if lastFlip[uid] and (now - lastFlip[uid]) < FLIP_COOLDOWN then return end

		local isOccupant = false
		for _, desc in car:GetDescendants() do
			if (desc:IsA("VehicleSeat") or desc:IsA("Seat")) and desc.Occupant then
				local p = Players:GetPlayerFromCharacter(desc.Occupant.Parent)
				if p == player then
					isOccupant = true
					break
				end
			end
		end
		if not isOccupant then return end

		local driveSeat = car:FindFirstChild("DriveSeat")
		if not driveSeat then return end

		local upVector = (driveSeat.CFrame * CFrame.Angles(math.pi/2, 0, 0)).LookVector
		local isUpsideDown = upVector.Y < -0.1

		local rightVector = driveSeat.CFrame.RightVector
		local forwardVector = driveSeat.CFrame.LookVector
		local tiltAngle = math.abs(math.asin(rightVector.Y)) + math.abs(math.asin(forwardVector.Y))
		local isStuck = tiltAngle > math.rad(45)

		if not isUpsideDown and not isStuck then
			return
		end

		local flipConstraint = driveSeat:FindFirstChild("Flip")
		if flipConstraint then
			if flipConstraint:IsA("AlignOrientation") then
				flipConstraint.Enabled = true
				task.delay(1.5, function()
					if flipConstraint and flipConstraint.Parent then
						flipConstraint.Enabled = false
					end
				end)
			elseif flipConstraint:IsA("BodyGyro") then
				flipConstraint.MaxTorque = Vector3.new(10000, 0, 10000)
				flipConstraint.P = 3000
				flipConstraint.D = 500
				task.delay(1.5, function()
					if flipConstraint and flipConstraint.Parent then
						flipConstraint.MaxTorque = Vector3.new(0, 0, 0)
						flipConstraint.P = 0
						flipConstraint.D = 0
					end
				end)
			end
		end

		lastFlip[uid] = now
	end)

	Players.PlayerRemoving:Connect(function(player)
		cleanupPlayer(player)
		lastEntryAttempt[player] = nil
		lastExitAttempt[player] = nil
		lastLockToggle[player] = nil
	end)
end

return EnterHandler
