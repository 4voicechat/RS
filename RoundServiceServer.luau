-- Connected Discord-GitHub
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local RoundServiceUtils = require(ReplicatedStorage.Shared.Services.RoundService.RoundServiceUtils)
local RoundTypes = require(ReplicatedStorage.Shared.Services.RoundService.RoundTypes) 
local Networker = require(ReplicatedStorage.Packages.Networker)
local Janitor = require(ReplicatedStorage.Packages.Janitor) 
local Signal = require(ReplicatedStorage.Packages.Signal) 

type Role = RoundTypes.Role 
type State = RoundTypes.State
type Winner = RoundTypes.Winner 

local MIN_PLAYERS = 1 
local INTERMISSION_TIME = 5 
local STARTING_TIME = 5
local ROUND_TIME = 180
local ENDING_TIME = 8 
local RESPAWN_TIME = 3 

local RoundServiceServer = {} 

function RoundServiceServer.init(self: RoundServiceServer)
	self.networker = Networker.server.new("RoundService", self, { self.getState }) -- exposes getState as a remote so late joiners can request the current state
	self.janitor = Janitor.new() -- collects every connection so destroy() can clean them all
	self.signal = Signal.new() -- fired at round end with the winner and roles for other systems
	self.state = "Intermission" -- start in intermission so the loop begins from a known state
	self.stateEndTime = nil -- nil means the current state has no timer
	self.winner = nil -- nil means nobody has won yet
	self.roles = {} -- [Player] = Role, filled when a round starts and cleared when it ends
	self.alive = {} -- [Player] = boolean, tracked separately so checkWin doesn't depend on Humanoid state
	self.map = nil -- the currently loaded map model

	Players.CharacterAutoLoads = false -- we control spawning so players don't appear mid-round
	for _, player in Players:GetPlayers() do -- covers players who joined before init ran
		self:setupPlayer(player)
	end

	self.janitor:Add(Players.PlayerAdded:Connect(function(player) -- handles players who join later
		self:setupPlayer(player)
	end))

	self.janitor:Add(Players.PlayerRemoving:Connect(function(player) -- a player leaving mid-round counts as dead
		if self.roles[player] then -- only matters if they were in this round
			self.alive[player] = false -- stop counting them as alive
			self:checkWin() -- their leaving may have decided the round
		end
	end))

	self.thread = task.spawn(function() -- run the round loop on its own thread so init returns immediately
		self:loop()
	end)
end

function RoundServiceServer.setupPlayer(self: RoundServiceServer, player: Player)
	self.janitor:Add(player.CharacterAdded:Connect(function(char) -- Janitor tracks it so the connection is cleaned with the service
		local humanoid = char:WaitForChild("Humanoid") :: Humanoid -- cast is safe because every R15/R6 character has a Humanoid
		humanoid.Died:Connect(function() -- no Janitor needed, it's destroyed with the character
			self:died(player) -- update alive tracking and check the win condition

			task.wait(RESPAWN_TIME)
			if player.Parent and not self.roles[player] then -- respawn only if still in game and not part of a live round
				player:LoadCharacter()
			end
		end)
	end))

	if not player.Character then -- manual spawn because CharacterAutoLoads is off
		task.spawn(player.LoadCharacter, player) -- spawned so a slow load doesn't block setup
	end
end

function RoundServiceServer.getState(self: RoundServiceServer, _player: Player)
	return self.state, self.stateEndTime, self.winner -- returns everything a new client needs to render the UI
end

function RoundServiceServer.setState(self: RoundServiceServer, state: State, duration: number?, winner: Winner?)
	self.state = state -- keep the server copy for getState and checkWin
	self.stateEndTime = if duration then workspace:GetServerTimeNow() + duration else nil -- absolute timestamp so clients can count down without drifting

	self.networker:setAll("stateEndTime", self.stateEndTime) -- sent first so the client has the timer when the state changes
	self.networker:setAll("winner", winner) -- sent before state so the UI can read it when it reacts
	self.networker:setAll("state", state) -- sent last because clients listen to this one to switch screens
end

function RoundServiceServer.getAlive(self: RoundServiceServer): { Player }
	local alive = {} -- fresh array each call so callers can't mutate internal state
	for player, isAlive in self.alive do
		if isAlive and player.Parent then -- Parent check skips players who left but weren't cleaned yet
			table.insert(alive, player)
		end
	end
	return alive
end

function RoundServiceServer.loop(self: RoundServiceServer)
	while true do -- the service runs rounds forever
		self:intermission() -- wait for players and rest
		if self:start() then -- start returns false if the round can't begin
			self:play() -- main gameplay phase
			self:finish() -- reveal results and clean up
		end
	end
end

function RoundServiceServer.intermission(self: RoundServiceServer)
	self:setState("Intermission") -- no timer while waiting for enough players
	while #Players:GetPlayers() < MIN_PLAYERS do
		task.wait(1) -- poll once a second, cheap and good enough here
	end

	self:setState("Intermission", INTERMISSION_TIME) -- timed countdown now that there are enough players
	task.wait(INTERMISSION_TIME)
end

function RoundServiceServer.start(self: RoundServiceServer): boolean
	local players = RoundServiceUtils.getPlayers() -- util filters out players who aren't ready
	if #players < MIN_PLAYERS then
		return false -- someone left during intermission
	end

	local map = RoundServiceUtils.pickMap() -- returns a clone of a random map, or nil if none exist
	if not map then
		task.wait(INTERMISSION_TIME) -- avoid a tight loop if maps are missing
		return false
	end

	map.Name = "CurrentMap" -- fixed name so other scripts can find it
	map.Parent = workspace -- parenting makes the map exist in the world
	self.map = map -- stored so cleanupRound can destroy it

	RoundServiceUtils.shuffle(players) -- in-place shuffle so roles are random
	for i, player in players do
		self.roles[player] = if i == 1 then "Murderer" elseif i == 2 then "Sheriff" else "Innocent" -- first two shuffled players get special roles
		self.alive[player] = true -- everyone starts alive
	end

	RoundServiceUtils.teleport(map, players) -- moves players to the map's spawn points
	self:setState("Starting", STARTING_TIME) -- clients show the "get ready" screen
	task.wait(STARTING_TIME)

	if #self:getAlive() < MIN_PLAYERS then -- people may have left or died during the countdown
		self:cleanupRound() -- undo setup so the next round starts clean
		return false
	end

	return true
end

function RoundServiceServer.play(self: RoundServiceServer)
	self:setState("Round", ROUND_TIME) -- starts the round timer on all clients
	local endTime = workspace:GetServerTimeNow() + ROUND_TIME -- local copy so the loop doesn't depend on the nilable property

	local sword = ServerStorage:FindFirstChild("ClassicSword") -- template tool, nil if it's missing
	if sword then
		for _, player in self:getAlive() do
			sword:Clone().Parent = player.Backpack -- each player gets their own copy; the template stays untouched
		end
	end

	self:checkWin() -- covers the case where the round is already decided at start

	while not self.winner and workspace:GetServerTimeNow() < endTime do -- stop on a win or when time runs out
		task.wait(0.25) -- short poll keeps timeout detection accurate without wasting time
	end

	self.winner = self.winner or "Innocents" -- if time ran out with no winner, innocents win
end

function RoundServiceServer.finish(self: RoundServiceServer)
	local reveal = {} -- string-keyed table because remotes can't send Instances as dictionary keys reliably
	for player, role in self.roles do
		reveal[tostring(player.UserId)] = role -- UserId strings are safe to send and easy to map back on the client

		if player.Parent then -- players who left have no Backpack or Character to clear
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:UnequipTools() -- moves held tools back to the Backpack so ClearAllChildren removes them
			end
			player.Backpack:ClearAllChildren() -- removes the swords so they can't be used between rounds
		end
	end

	self:setState("Ending", ENDING_TIME, self.winner) -- shows the result screen with the winner
	self.networker:fireAll("rolesRevealed", reveal) -- one-time event, so a remote fits better than a property
	self.signal:Fire(self.winner, self.roles) -- lets other server systems (stats, rewards) react

	task.wait(ENDING_TIME)
	self:cleanupRound()
end

function RoundServiceServer.checkWin(self: RoundServiceServer)
	if self.state ~= "Round" or self.winner then
		return -- ignore deaths outside the round, and don't overwrite an existing winner
	end

	local alive = self:getAlive()
	local murdererAlive = false
	for _, player in alive do
		if self.roles[player] == "Murderer" then
			murdererAlive = true
			break -- no need to keep looking once found
		end
	end

	if not murdererAlive then
		self.winner = "Innocents" -- murderer is dead
	elseif #alive == 1 then
		self.winner = "Murderer" -- only the murderer is left
	end
end

function RoundServiceServer.died(self: RoundServiceServer, player: Player)
	if not self.alive[player] then
		return -- not in the round, or already counted as dead
	end

	self.alive[player] = false -- mark dead before checking the win condition
	self:checkWin()
end

function RoundServiceServer.cleanupRound(self: RoundServiceServer)
	for player in self.roles do
		if player.Parent then
			task.spawn(player.LoadCharacter, player) -- respawn everyone in the lobby; spawned so one slow load doesn't delay the rest
		end
	end

	if self.map then
		self.map:Destroy() -- removes the map and frees its memory
		self.map = nil
	end

	self.roles = {} -- clearing roles also re-enables the lobby respawn check in setupPlayer
	self.alive = {}
	self.winner = nil
end

function RoundServiceServer.destroy(self: RoundServiceServer)
	task.cancel(self.thread) -- stops the round loop first so it can't touch destroyed objects
	self.janitor:Destroy() -- disconnects every tracked connection
	self.networker:destroy() -- removes the remotes
end

type RoundServiceServer = typeof(RoundServiceServer) & {
	networker: Networker.Server,
	janitor: Janitor.Janitor,
	signal: Signal.Signal<Winner, { [Player]: Role }>,
	thread: thread,
	state: State,
	stateEndTime: number?,
	winner: Winner?,
	roles: { [Player]: Role },
	alive: { [Player]: boolean },
	map: Model?,
}

return RoundServiceServer :: RoundServiceServer -- cast so requiring scripts get the full typed class
