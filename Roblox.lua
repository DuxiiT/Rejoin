--==================================================
-- ReJoin V3 – ANTI-KICK PRODUCTION (AUTOEXEC)
--==================================================

repeat task.wait() until game:IsLoaded()
task.wait(3)

--// Services
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local NetworkClient = game:GetService("NetworkClient")
local HttpService = game:GetService("HttpService")

--// Wait for LocalPlayer
repeat task.wait() until Players.LocalPlayer
local player = Players.LocalPlayer
local PLACE_ID = game.PlaceId

--// WebSocket Configuration
local WS_URL = "ws://127.0.0.1:28745"
local socket
local wsConnected = false

--// Configuration
local VERSION = "2.2"
local REJOIN_DELAY = 0.5
local HEARTBEAT_TIMEOUT = 15
local WS_PING_INTERVAL = 3
local SEND_RETRY_ATTEMPTS = 3

--// State Management
local rejoining = false
local teleporting = false
local userInitiatedTeleport = false
local lastHeartbeat = tick()
local startTime = tick()
local shuttingDown = false
local eventSent = false
local kickDetected = false
local lastEventType = nil
local lastEventTime = 0
local EVENT_DEDUP_TIMEOUT = 1  -- Prevent duplicate events within 1 second

--==================================================
-- WebSocket Communication
--==================================================

local function sendWSEvent(eventType, reason, critical)
	if not socket or not wsConnected then return false end
	
	-- Prevent duplicate events of the same type within timeout window
	if lastEventType == eventType and (tick() - lastEventTime) < EVENT_DEDUP_TIMEOUT then
		return false
	end
	
	if eventSent and rejoining then return false end -- Prevent duplicate sends during rejoin
	
	local attempts = critical and SEND_RETRY_ATTEMPTS or 1
	
	for i = 1, attempts do
		local success = pcall(function()
			socket:Send(HttpService:JSONEncode({
				type = eventType,
				reason = reason,
				placeId = PLACE_ID,
				userId = player.UserId,
				username = player.Name,
				version = VERSION,
				timestamp = os.time(),
				uptime = math.floor(tick() - startTime)
			}))
		end)

		if success then 
			eventSent = true
			lastEventType = eventType
			lastEventTime = tick()
			return true 
		end
		if i < attempts then task.wait(0.05) end
	end
	
	return false
end

local function closeWebSocket(reason)
	if not socket then return end
	shuttingDown = true
	sendWSEvent("WS_CLOSE", reason, true)
	task.wait(0.3)
	pcall(function() socket:Close() end)
	wsConnected = false
end

--==================================================
-- WebSocket Initialization
--==================================================

local function initWebSocket()
	pcall(function()
		socket = WebSocket.connect(WS_URL)
		wsConnected = true
		
		socket.OnMessage:Connect(function(message) end)
		socket.OnClose:Connect(function()
			if not shuttingDown then wsConnected = false end
		end)
		
		task.wait(0.3)
		sendWSEvent("CONNECT", "Client connected", false)
		-- Don't reset eventSent for CONNECT to allow proper deduplication
	end)
end

task.wait(2)
initWebSocket()

--==================================================
-- Heartbeat System
--==================================================

task.spawn(function()
	task.wait(7)
	while task.wait(WS_PING_INTERVAL) do
		if wsConnected and not shuttingDown and not teleporting then
			sendWSEvent("HEARTBEAT", "alive", false)
		end
	end
end)

--==================================================
-- ReJoin Logic
--==================================================

local function rejoin(reason)
	if rejoining or shuttingDown or teleporting then return end
	rejoining = true
	
	-- Only send event if not already sent
	if not eventSent then
		eventSent = false
		sendWSEvent("ANTI_KICK", reason, true)
	end
	
	task.wait(REJOIN_DELAY)
	
	pcall(function() TeleportService:Teleport(PLACE_ID, player) end)
end

--==================================================
-- Kick Detection
--==================================================

task.spawn(function()
	task.wait(3)
	pcall(function()
		local gui = CoreGui:WaitForChild("RobloxPromptGui", 15)
		if gui and gui:FindFirstChild("promptOverlay") then
			gui.promptOverlay.ChildAdded:Connect(function(child)
				if child.Name == "ErrorPrompt" and not teleporting and not rejoining then
					-- Send KICK event only once
					if lastEventType ~= "KICK" or (tick() - lastEventTime) >= EVENT_DEDUP_TIMEOUT then
						sendWSEvent("KICK", "Kicked from the game, rejoining", true)
						task.wait(0.2)
						rejoin("Kicked from the game, rejoining")
					end
				end
			end)
		end
	end)
end)

NetworkClient.ChildRemoved:Connect(function()
	task.wait(0.5) -- Wait to see if it's a kick
	
	-- Only handle if not already handling another event
	if rejoining or teleporting or shuttingDown then return end
	
	-- Check if this is a duplicate of recent kick event
	if lastEventType == "KICK" and (tick() - lastEventTime) < EVENT_DEDUP_TIMEOUT then
		return
	end
	
	-- Only send NETWORK_ERROR if we haven't recently sent it
	if lastEventType ~= "NETWORK_ERROR" or (tick() - lastEventTime) >= EVENT_DEDUP_TIMEOUT then
		sendWSEvent("NETWORK_ERROR", "Lost connection, rejoining", true)
		task.wait(0.2)
		rejoin("Lost connection, rejoining")
	end
end)

TeleportService.TeleportInitFailed:Connect(function(p, result, msg)
	if not userInitiatedTeleport and not rejoining and not teleporting then
		-- Only send if not a duplicate
		if lastEventType ~= "TELEPORT_FAILED" or (tick() - lastEventTime) >= EVENT_DEDUP_TIMEOUT then
			sendWSEvent("TELEPORT_FAILED", "Teleport failed, retrying", true)
			task.wait(0.2)
			rejoin("Teleport failed, retrying")
		end
	end
end)

--==================================================
-- Teleport Monitoring
--==================================================

player.OnTeleport:Connect(function(state)
	if state == Enum.TeleportState.Started then
		teleporting = true
		userInitiatedTeleport = true
		-- Only send if not already sent
		if lastEventType ~= "SERVER_HOP" or (tick() - lastEventTime) >= EVENT_DEDUP_TIMEOUT then
			sendWSEvent("SERVER_HOP", "Server hop started", true)
		end
		
	elseif state == Enum.TeleportState.InProgress then
		task.spawn(function()
			task.wait(0.5)
			closeWebSocket("Server hop in progress")
		end)
		
	elseif state == Enum.TeleportState.Failed then
		if userInitiatedTeleport then
			teleporting = false
			userInitiatedTeleport = false
			-- Only send if not already sent
			if lastEventType ~= "TELEPORT_FAILED" or (tick() - lastEventTime) >= EVENT_DEDUP_TIMEOUT then
				sendWSEvent("TELEPORT_FAILED", "Server hop failed, retrying", true)
				task.wait(0.2)
				rejoin("Server hop failed, retrying")
			end
		end
	end
end)

--==================================================
-- Network Freeze Watchdog
--==================================================

RunService.Heartbeat:Connect(function()
	lastHeartbeat = tick()
end)

task.spawn(function()
	task.wait(5)
	while task.wait(1) do
		if not teleporting and not shuttingDown and not rejoining then
			local elapsed = tick() - lastHeartbeat
			if elapsed > HEARTBEAT_TIMEOUT then
				-- Only send if not already sent recently
				if lastEventType ~= "NETWORK_FREEZE" or (tick() - lastEventTime) >= EVENT_DEDUP_TIMEOUT then
					sendWSEvent("NETWORK_FREEZE", "Network freeze detected, rejoining", true)
					task.wait(0.2)
					rejoin("Network freeze detected, rejoining")
				end
				break
			end
		end
	end
end)

--==================================================
-- Shutdown Handlers
--==================================================

game:BindToClose(function()
	closeWebSocket("Game closed")
end)

Players.PlayerRemoving:Connect(function(plr)
	if plr == player then
		closeWebSocket("Player left")
	end
end)

--==================================================
-- Status Monitor
--==================================================

task.spawn(function()
	task.wait(10)
	while task.wait(60) do
		if not shuttingDown and wsConnected then
			pcall(function()
				socket:Send(HttpService:JSONEncode({
					type = "STATUS",
					userId = player.UserId,
					timestamp = os.time()
				}))
			end)
		end
	end
end)
