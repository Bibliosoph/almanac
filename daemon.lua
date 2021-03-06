---- Dependencies ---------------------------------------------
-- LuaJIT
package.path = package.path .. ";./lib/?.lua;~/.bibliosoph/?.lua;~/.bibliosoph/lib/?.lua"
local lbry = require "luabry.lbry"
local jrpc = require "luajrpc.jrpc"
local socket = require "socket"
local json = require "json"
local http = require "socket.http"
local ltn12 = require "ltn12"

---- Daemon Details -------------------------------------------
-- Bind IP
local bind_ip = "*"

-- Bind port
local bind_port = 5280

---- Version --------------------------------------------------
local bibver = 20180904

---- State ----------------------------------------------------
local api = {}
local files = require "bibdir"
local bibcrypt = require "bibcrypt"
local log = assert(io.open(files.log_file_path, "w+"))
local current_keys = {}

---- API Functions --------------------------------------------
api.version = function()
	return {result = bibver}
end

api.status = function()
	return {result = {
			version = bibver,
			running = true,
			time    = os.time(),
			uptime  = os.clock() * 60,
		}
	}
end

api.encrypt_keys = function(inp)
	if type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.encryption_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_nonce' field must be a string",
			}
		}
	end
	
	local keyfiledata
	local status, err = pcall(function() keyfiledata = bibcrypt.construct.keyfiledata(current_keys, inp.encryption_key, inp.encryption_nonce) end)
	
	if status then
		if inp.flush_to_key_file then
			local keyfile = io.open(files.key_file_path, "w+b")
			keyfile:write(keyfiledata)
			keyfile:flush()
			keyfile:close()
		end
		
		return {result = keyfiledata}
	else
		return {error = {
				code    = -32602,
				message = err,
			}
		}
	end
end

api.decrypt_keys = function(inp)
	if type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.encryption_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_nonce' field must be a string",
			}
		}
	end
	
	local keyfiledata
	local keyfile = io.open(files.key_file_path, "a+b")
	local status, err = pcall(function() keyfiledata = bibcrypt.deconstruct.keyfiledata(keyfile:read("*a"), inp.encryption_key, inp.encryption_nonce) end)
	keyfile:close()
	
	if status then
		if inp.flush_to_internal_table then
			current_keys = keyfiledata
		end
		
		return {result = keyfiledata}
	else
		return {error = {
				code    = -32602,
				message = err,
			}
		}
	end
end

api.download_key = function(inp)
	if type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.encryption_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_nonce' field must be a string",
			}
		}
	elseif type(inp.uri) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameters: 'uri' field must be a string",
			}
		}
	end

	local response, request = {}, lbry.stream_cost_estimate({uri = inp.uri})
	request.sink = ltn12.sink.table(response)
	http.request(request)
	
	if response == "" then
		return {error = {
				code    = -32601,
				message = "LBRYd returned nil, make sure it's running and responsive",
			}
		}
	end
	
	local status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	-- Check if the URI is resolvable.
	if response.error then
		return {error = response.error}
	elseif not response.result then
		return {error = {
				code    = -32602,
				message = "Could not resolve uri",
			}
		}
	-- Check if the key isn't free but the caller isn't willing to pay.
	elseif response.result > 0 and not inp.will_pay then
		return {error = {
				code    = -32602,
				message = "Key has fee, set parameter 'will_pay' to 'true'",
			}
		}
	end
	
	response, request = {}, lbry.get({uri = inp.uri})
	request.sink = ltn12.sink.table(response)
	http.request(request)
	
	status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	-- Return error if there was one.
	if response.error then
		return {error = response.error}
	end
	
	response = response.result
	
	file, err = io.open(response.download_path, "r")
	
	if not file or err then
		return {error = {
				code    = -32603,
				message = "Could not open downloaded file at '" .. response.download_path .. "'",
			}
		}
	end
	
	local key = file:read("*a")
	file:close()
	
	local status, err = pcall(function() key = bibcrypt.deconstruct.authregister(key, inp.encryption_key, inp.encryption_nonce) end)
	
	if status then
		return {result = key}
	else
		return {error = {
				code    = -32602,
				message = err,
			}
		}
	end
end

api.generate_aes_key = function(inp)
	local key = bibcrypt.construct.aeskey()
	
	if inp.flush_to_internal_table then
		current_keys[#current_keys + 1] = key
	end
	
	return {result = key}
end

api.upload_key = function(inp)
	if type(inp.key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'key' field must be a string",
			}
		}
	elseif type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.encryption_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_nonce' field must be a string",
			}
		}
	end
	
	local key
	local status, err = pcall(function() key = bibcrypt.construct.authregister(inp.key, inp.encryption_key, inp.encryption_nonce) end)
	
	if not status then
		return {error = {
				code    = -32602,
				message = err
			}
		}
	end
	
	local temp_key_file = io.open(files.scratchpad_file_path, "w+b")
	temp_key_file:write(key)
	temp_key_file:flush()
	temp_key_file:close()
	
	inp.key = nil
	inp.encryption_key = nil
	inp.encryption_nonce = nil
	
	inp.file_path = files.scratchpad_file_path
	
	local response, request = {}, lbry.publish(inp)
	request.sink = ltn12.sink.table(response)
	http.request(request)

	if response == "" then
		return {error = {
				code    = -32601,
				message = "LBRYd returned nil, make sure it's running and responsive",
			}
		}
	end
	
	status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	return response
end

-- This is basically just a glorified 'ping' command.
api.get_lbryd_status = function(inp)
	if type(inp.timeout) ~= "nil" and type(inp.timeout) ~= "number" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'timeout' field must be unspecified or a number",
			}
		}
	end
	
	local response, request = {}, lbry.status()
	request.sink = ltn12.sink.table(response)
	request.headers.TIMEOUT = inp.timeout
	http.request(request)
	
	if response == "" then
		return {error = {
				code    = -32601,
				message = "LBRYd returned nil, make sure it's running and responsive",
			}
		}
	end
	
	status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	return response
end

api.upload_message = function(inp)
	if type(inp.message) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'message' field must be a string",
			}
		}
	elseif type(inp.message_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'message_nonce' field must be a string",
			}
		}
	elseif type(inp.last_message_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'last_message_nonce' field must be a string",
			}
		}
	elseif type(inp.alias) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'alias' field must be a string",
			}
		}
	elseif type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.encryption_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_nonce' field must be a string",
			}
		}
	end
	
	local message
	local status, err = pcall(function() message = bibcrypt.construct.message(inp.message, inp.message_nonce, inp.last_message_nonce, inp.alias, inp.encryption_key, inp.encryption_nonce) end)
	
	if not status then
		return {error = {
				code    = -32602,
				message = err
			}
		}
	end
	
	local temp_key_file = io.open(files.scratchpad_file_path, "w+b")
	temp_key_file:write(key)
	temp_key_file:flush()
	temp_key_file:close()
	
	inp.message = nil
	inp.message_nonce = nil
	inp.last_message_nonce = nil
	inp.alias = nil
	inp.encryption_key = nil
	inp.encryption_nonce = nil
	
	inp.file_path = files.scratchpad_file_path
	
	local response, request = {}, lbry.publish(inp)
	request.sink = ltn12.sink.table(response)
	http.request(request)

	if response == "" then
		return {error = {
				code    = -32601,
				message = "LBRYd returned nil, make sure it's running and responsive",
			}
		}
	end
	
	status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	return response
end

api.download_key = function(inp)
	if type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.encryption_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_nonce' field must be a string",
			}
		}
	elseif type(inp.uri) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameters: 'uri' field must be a string",
			}
		}
	end

	local response, request = {}, lbry.stream_cost_estimate({uri = inp.uri})
	request.sink = ltn12.sink.table(response)
	http.request(request)
	
	if response == "" then
		return {error = {
				code    = -32601,
				message = "LBRYd returned nil, make sure it's running and responsive",
			}
		}
	end
	
	local status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	-- Check if the URI is resolvable.
	if response.error then
		return {error = response.error}
	elseif not response.result then
		return {error = {
				code    = -32602,
				message = "Could not resolve uri",
			}
		}
	-- Check if the key isn't free but the caller isn't willing to pay.
	elseif response.result > 0 and not inp.will_pay then
		return {error = {
				code    = -32602,
				message = "Key has fee, set parameter 'will_pay' to 'true'",
			}
		}
	end
	
	response, request = {}, lbry.get({uri = inp.uri})
	request.sink = ltn12.sink.table(response)
	http.request(request)
	
	status = pcall(function() response = json.decode(table.concat(response)) end)
	
	if not status then
		return {error = {
				code    = -32601,
				message = "LBRYd failed to produce anything intelligible (aka json)",
			}
		}
	end
	
	-- Return error if there was one.
	if response.error then
		return {error = response.error}
	end
	
	response = response.result
	
	file, err = io.open(response.download_path, "r")
	
	if not file or err then
		return {error = {
				code    = -32603,
				message = "Could not open downloaded file at '" .. response.download_path .. "'",
			}
		}
	end
	
	local message = file:read("*a")
	file:close()
	
	local status, err = pcall(function() message = bibcrypt.deconstruct.message(message, inp.encryption_key, inp.encryption_nonce) end)
	
	if status then
		return {result = message}
	else
		return {error = {
				code    = -32602,
				message = err,
			}
		}
	end
end

function api.verify_message(inp)
	if type(inp.message_text) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'message_text' field must be a string",
			}
		}
	elseif type(inp.encryption_key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'encryption_key' field must be a string",
			}
		}
	elseif type(inp.message_nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'message_nonce' field must be a string",
			}
		}
	elseif type(inp.message_hash) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'message_hash' field must be a string",
			}
		}
	end
	
	local verified
	local status, err = pcall(function() verified = bibcrypt.verify.message(inp.message_text, inp.encryption_key, inp.message_nonce, inp.message_hash) end)
	
	if status then
		return {result = verified}
	else
		return {error = {
				code    = -32602,
				message = err,
			}
		}
	end
end

---- Public Interface -----------------------------------------
local function json_interface(json_inp)
	local inp
	local status = pcall(function() inp = json.decode(json_inp) end)
	
	if not status then
		return json.encode{error = {
				code = -32700,
				jsonrpc = "2.0"
			}
		}
	end
	
	log:write("[ " .. os.time() .. " ]\tDecoded input\n")
	
	if not (jrpc.validate_request(inp) or jrpc.validate_batch_request(inp))  then
		if inp.id then
			return json.encode{error = {
					code = -32600,
					message = err,
				},
				id = inp.id,
				jsonrpc = "2.0"
			}
		else
			log:write("[ " .. os.time() .. " ]\tNo input ID\n")
			
			return
		end
	end
	
	if not (inp.method and api[inp.method:lower()]) then
		if jrpc.validate_batch_request(inp) then
			local resp_table = {}
			
			for _,v in ipairs(inp) do
				resp_table[#resp_table + 1] = json_interface(json.encode(v))
			end
			
			if #resp_table == 0 then
				log:write("[ " .. os.time() .. " ]\tEmpty batch\n")
				
				return
			else
				return json.encode(resp_table)
			end
		end
		
		log:write("[ " .. os.time() .. " ]\tCouldn't find method\n")
		
		return json.encode{error = {
				code = -32601,
				message = "Method does not exist",
			},
			id = inp.id,
			jsonrpc = "2.0"
		}
	end
	
	local result = api[inp.method:lower()](inp.params or {})
	
	if not inp.id then
		log:write("[ " .. os.time() .. " ]\tStill no input ID\n")
		
		return
	end
	
	result.jsonrpc = "2.0"
	result.id = inp.id
	
	return json.encode(result)
end

---- Server ---------------------------------------------------

local sock = assert(socket.bind(bind_ip, bind_port))
sock:setoption("tcp-nodelay", true)
sock:settimeout(0)

local clients = {}

while true do
	for _,client_data in pairs(clients) do
		local client = client_data.sock
		local data, err = client:receive(1)
		
		if err == "closed" then
			log:write("[ " .. os.time() .. " ]\tRemoved a client: " .. client:getsockname() .. "\n")
			
			clients[client] = nil
			client:close()
		elseif err == "timeout" then
			local filt_mess = client_data.message:gsub("^POST.-\r\n\r\n", "", 1)
			log:write("[ " .. os.time() .. " ]\tFiltered input:\n" .. (filt_mess or "") .. "\n")
			
			if not filt_mess or filt_mess == "" then
				log:write("[ " .. os.time() .. " ]\tClosed socket on invalid request:\n" .. client_data.message .. "\n")
			else
				log:write("[ " .. os.time() .. " ]\tProcessing command:\n" .. filt_mess .. "\n")
				local tab = json_interface(filt_mess)
				
				if tab and tab ~= "" then
					local newtab = mime.normalize()(tab .. "\n")
					client:send("HTTP/1.1 200 OK\r\nContent-Length: " .. newtab:len() .. "\r\nContent-Type: application/json-rpc\r\n\r\n" .. newtab)
					
					socket.sleep(0.0001)
				end
			end
			
			clients[client] = nil
			client:close()
		elseif data then
			client_data.message = client_data.message .. data
		end
	end
	
	while true do
		local client, err = sock:accept()
		
		if client then
			clients[client] = {
				sock = client,
				message = ""
			}
			
			client:setoption("tcp-nodelay", true)
			client:settimeout(0)
			
			log:write("[ " .. os.time() .. " ]\tAdded a client: " .. client:getsockname() .. "\n")
		else
			if err ~= "timeout" then
				log:write("[ " .. os.time() .. " ]\tFailed to add a client: " .. err .. "\n")
			end
			
			break
		end
	end
	
	log:flush()
	
	socket.sleep(0.0001)
end

log:close()
