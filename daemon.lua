---- Dependencies ---------------------------------------------
-- LuaJIT
local lbry = require "luabry.lbry"
local jrpc = require "luajrpc.jrpc"
local socket = require "socket"
local json = require "cjson"
local http = require "socket.http"
local ltn12 = require "ltn12"
local ffi = require "ffi"
local mime = require "mime"

---- Daemon Details -------------------------------------------
-- Bind IP
local bind_ip = "*"

-- Bind port
local bind_port = 5280

---- Version --------------------------------------------------
local bibver = 20180716

---- State ----------------------------------------------------
local api = {}
local bibcrypt = require "lib.bibcrypt"
local log = assert(io.open("biblio.log", "w+"))

---- API Functions --------------------------------------------
api.version = function()
	return {result = bibver}
end

api.status = function()
	return {result = {
			version = bibver,
			running = true,
			time    = os.time(),
			uptime  = os.clock(),
		}
	}
end

api.download_key = function(inp)
	if type(inp.aeskey) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'aeskey' field must be a string",
			}
		}
	elseif type(inp.nonce) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'aesnonce' field must be a string",
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
	response = table.concat(response)
	
	if response == "" then
		return {error = {
				code    = -32601,
				message = "LBRY daemon returned nil, make sure it's running and responsive",
			}
		}
	end
	
	response = json.decode(response)
	
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
	response = json.decode(table.concat(response))
	
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
	
	
	
	return {result = key}
end

api.generate_aes_key = function()
	return bibcrypt.construct.aeskey()
end

--[[
api.upload_key = function(inp)
	if type(inp.key) ~= "string" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'key' field must be a Base64 string",
			}
		}
	elseif not isvalid.base64(inp.key) then
		return {error = {
				code    = -32602,
				message = "Malformed parameter: 'key' field is not a valid Base64 string",
			}
		}
	elseif type(inp.bid) ~= "number" then
		return {error = {
				code    = -32602,
				message = "Invalid parameter: 'bid' field must be a number",
			}
		}
	elseif inp.bid < 0 then
		return {error = {
				code = -32602,
				message = "Malformed parameter: 'bid' field is not non-negative",
			}
		}
	end
end
]]

---- Public Interface -----------------------------------------
local function json_interface(json_inp)
	local status = pcall(function() json.decode(json_inp) end)
	
	if not status then
		return json.encode{error = {
				code = -32700,
				jsonrpc = "2.0"
			}
		}
	end
	
	local inp = json.decode(json_inp)
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
	
	if not api[inp.method:lower()] then
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
	
	local result = api[inp.method:lower()](inp.params)
	
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
				else
					
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