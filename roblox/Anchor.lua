local RunService = game:GetService("RunService")

local Bridge = require(script.Bridge)
local Janitor = require(script.Parent.Janitor)
local Promise = require(script.Parent.Promise)
local GoodSignal = require(script.Parent.GoodSignal)

local IsServer = RunService:IsServer()

local Anchor = {
	Bridge = Bridge,
}

local State = {
	Started = false,
	Starting = false,
	StartPromise = nil,
	Storage = {
		Services = {},
		Controllers = {},
		Order = {},
	},
	ProxyCache = {},
	MetatableCache = {},
}

local SETTINGS = {
	DebugMode = false,
	ErrorOnMissingModule = true,
	InitTimeout = 30,
	MaxInitRetries = 1,
	StrictMode = false,
	RetryBackoff = 0.5,
}

local function log(...)
	if SETTINGS.DebugMode then
		print("[Anchor]", ...)
	end
end

local function warnLog(...)
	warn("[Anchor]", ...)
end

local function getContainer()
	return IsServer and State.Storage.Services or State.Storage.Controllers
end

local function isPromiseLike(value)
	return type(value) == "table" and type(value.andThen) == "function" and type(value.catch) == "function"
end

local function sortModulesByDependencies()
	local container = getContainer()
	local visited = {}
	local stack = {}
	local sorted = {}

	local function visit(name)
		local currentState = visited[name]
		if currentState == "visiting" then
			table.insert(stack, name)
			error("Circular dependency detected: " .. table.concat(stack, " -> "))
		end
		if currentState == "visited" then
			return
		end

		visited[name] = "visiting"
		table.insert(stack, name)

		local moduleData = container[name]
		local dependencies = moduleData and moduleData.Dependencies
		if dependencies then
			for _, dependency in ipairs(dependencies) do
				if not container[dependency] then
					warnLog(("Missing dependency '%s' required by '%s'"):format(dependency, name))
				else
					visit(dependency)
				end
			end
		end

		visited[name] = "visited"
		table.remove(stack)
		table.insert(sorted, name)
	end

	local entries = {}
	for name, moduleData in pairs(container) do
		table.insert(entries, {
			Name = name,
			Order = moduleData.LoadOrder or 999,
		})
	end

	table.sort(entries, function(a, b)
		if a.Order == b.Order then
			return a.Name < b.Name
		end
		return a.Order < b.Order
	end)

	for _, entry in ipairs(entries) do
		visit(entry.Name)
	end

	return sorted
end

local function injectHelpers(moduleData)
	if not moduleData.Janitor then
		moduleData.Janitor = Janitor.new()
	end

	if not moduleData.CreateSignal then
		function moduleData:CreateSignal()
			local signal = GoodSignal.new()
			self.Janitor:Add(signal, "DisconnectAll")
			return signal
		end
	end

	if not moduleData.Destroy then
		function moduleData:Destroy()
			if self.Janitor then
				self.Janitor:Destroy()
			end
		end
	end
end

local function runInitWithRetry(name, moduleData)
	return Promise.new(function(resolve, reject)
		local attempts = 0

		local function tryInit()
			attempts += 1
			log(("Initializing %s (attempt %d/%d)"):format(name, attempts, SETTINGS.MaxInitRetries))

			local ok, result = pcall(function()
				return moduleData:Init()
			end)

			if not ok then
				warnLog("Init error:", name, result)
				if attempts >= SETTINGS.MaxInitRetries then
					reject(result or ("Init failed: " .. name))
					return
				end

				task.delay(SETTINGS.RetryBackoff * attempts, tryInit)
				return
			end

			if isPromiseLike(result) then
				result
					:andThen(function()
						resolve(true)
					end)
					:catch(function(err)
						warnLog("Async Init failed:", name, err)
						reject(err or ("Init promise rejected: " .. name))
					end)
			else
				resolve(true)
			end
		end

		tryInit()
	end):timeout(SETTINGS.InitTimeout)
end

local function startModule(name, moduleData)
	if type(moduleData.Start) ~= "function" then
		return
	end

	task.defer(function()
		local ok, err = pcall(function()
			moduleData:Start()
		end)

		if ok then
			log("Started:", name)
		else
			warnLog("Start failed:", name, err)
		end
	end)
end

function Anchor.Start()
	if State.Started then
		return Promise.resolve("Already started")
	end

	if State.Starting and State.StartPromise then
		return State.StartPromise
	end

	State.Starting = true

	State.StartPromise = Promise.new(function(resolve, reject)
		local container = getContainer()
		local sortedModules = sortModulesByDependencies()
		local initPromises = {}

		log("Starting", IsServer and "Services" or "Controllers", "- Count:", #sortedModules)

		for _, name in ipairs(sortedModules) do
			local moduleData = container[name]
			if type(moduleData.Init) == "function" then
				table.insert(initPromises, runInitWithRetry(name, moduleData))
			end
		end

		Promise.allSettled(initPromises):andThen(function(results)
			local failures = 0
			for _, result in ipairs(results) do
				if result.status == "Rejected" then
					failures += 1
				end
			end

			if failures > 0 and SETTINGS.StrictMode then
				State.Starting = false
				State.StartPromise = nil
				reject(("%d modules failed during Init"):format(failures))
				return
			end

			for _, name in ipairs(sortedModules) do
				startModule(name, container[name])
			end

			State.Started = true
			State.Starting = false
			log("Anchor Started")
			resolve("Success")
		end):catch(function(err)
			State.Starting = false
			State.StartPromise = nil
			reject(err)
		end)
	end)

	return State.StartPromise
end

function Anchor.Get(name: string)
	if IsServer then
		local service = State.Storage.Services[name]
		if service then
			return service
		end

		if SETTINGS.ErrorOnMissingModule then
			error("Service not found: " .. name)
		end
		return nil
	end

	local controller = State.Storage.Controllers[name]
	if controller then
		return controller
	end

	if State.ProxyCache[name] then
		return State.ProxyCache[name]
	end

	local proxy = Anchor._CreateServiceProxy(name)
	State.ProxyCache[name] = proxy
	return proxy
end

function Anchor.GetServices()
	if not State.MetatableCache.Services then
		State.MetatableCache.Services = {
			__index = function(_, key)
				return Anchor.Get(key)
			end,
		}
	end

	return setmetatable({}, State.MetatableCache.Services)
end

function Anchor.GetControllers()
	if not State.MetatableCache.Controllers then
		State.MetatableCache.Controllers = {
			__index = function(_, key)
				return Anchor.Get(key)
			end,
		}
	end

	return setmetatable({}, State.MetatableCache.Controllers)
end

function Anchor._CreateServiceProxy(serviceName: string)
	local proxy = {}
	local clientProxy = {}
	local identifierCache = {}

	local function getIdentifier(key)
		if not identifierCache[key] then
			identifierCache[key] = Bridge.CreateIdentifier(serviceName .. "_" .. key)
		end
		return identifierCache[key]
	end

	setmetatable(clientProxy, {
		__index = function(_, key)
			local identifier = getIdentifier(key)
			return {
				Connect = function(_, fn)
					return identifier:Connect(fn)
				end,
				Fire = function(_, ...)
					return identifier:Fire(...)
				end,
				Invoke = function(_, ...)
					return identifier:Invoke(...)
				end,
				SetCallback = function(_, fn)
					return identifier:SetCallback(fn)
				end,
				FireClient = function(_, ...)
					return identifier:FireClient(...)
				end,
				FireAll = function(_, ...)
					return identifier:FireAll(...)
				end,
			}
		end,
	})

	setmetatable(proxy, {
		__index = function(_, key)
			if key == "Client" then
				return clientProxy
			end
			return getIdentifier(key)
		end,
	})

	return proxy
end

if IsServer then
	function Anchor.CreateService(moduleData: {
		Name: string,
		Client: { [string]: any }?,
		Dependencies: { string }?,
		LoadOrder: number?,
		[string]: any,
	})
		if not moduleData.Name then
			error("Service must have Name")
		end
		if State.Storage.Services[moduleData.Name] then
			warnLog("Service overwriting:", moduleData.Name)
		end

		injectHelpers(moduleData)

		if moduleData.Client then
			for key, _ in pairs(moduleData.Client) do
				moduleData.Client[key] = Bridge.CreateIdentifier(moduleData.Name .. "_" .. key)
			end
		end

		State.Storage.Services[moduleData.Name] = moduleData
		table.insert(State.Storage.Order, moduleData.Name)
		log("Created Service:", moduleData.Name)
		return moduleData
	end

	Anchor.RemoteEvent = "RemoteEvent"
	Anchor.RemoteFunction = "RemoteFunction"

	game:BindToClose(function()
		log("Cleaning up...")
		for _, name in ipairs(State.Storage.Order) do
			local service = State.Storage.Services[name]
			if service and type(service.Destroy) == "function" then
				pcall(function()
					service:Destroy()
				end)
			end
		end
		task.wait(2)
	end)
else
	function Anchor.CreateController(moduleData: {
		Name: string,
		Dependencies: { string }?,
		LoadOrder: number?,
		[string]: any,
	})
		if not moduleData.Name then
			error("Controller must have Name")
		end
		if State.Storage.Controllers[moduleData.Name] then
			warnLog("Controller overwriting:", moduleData.Name)
		end

		injectHelpers(moduleData)

		State.Storage.Controllers[moduleData.Name] = moduleData
		table.insert(State.Storage.Order, moduleData.Name)
		log("Created Controller:", moduleData.Name)
		return moduleData
	end
end

function Anchor.SetDebugMode(enabled: boolean)
	SETTINGS.DebugMode = enabled
end

function Anchor.SetStrictMode(enabled: boolean)
	SETTINGS.StrictMode = enabled
end

function Anchor.WaitForModule(name: string, timeout: number?)
	local maxTime = timeout or 10
	local startTime = time()
	local container = getContainer()

	while time() - startTime < maxTime do
		if container[name] then
			return container[name]
		end
		task.wait(0.1)
	end

	error("Timeout waiting for: " .. name)
end

return Anchor
