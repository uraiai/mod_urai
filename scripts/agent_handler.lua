-- Read WebSocket URL from command line arguments
local ws_url = argv[1]
if not ws_url then
  freeswitch.consoleLog("CRIT", "agent_handler.lua: WebSocket URL not provided as an argument.\n")
  return
end

-- Get session and uuid
local uuid = session:get_uuid()


-- Force full answer state
local state = session:getState()
freeswitch.consoleLog("INFO", "agent_handler.lua: Initial call state: " .. state .. "\n")
if state == "CS_EXECUTE" then
  freeswitch.consoleLog("INFO", "agent_handler.lua: Call not in EXECUTE state, attempting to answer again\n")
  session:answer()
  session:sleep(100)
end

-- Load dkjson library
local json = require("dkjson")
if not json then
  freeswitch.consoleLog("CRIT", "agent_handler.lua: 'dkjson' library not found. Please install it.\n")
  session:hangup()
  return
end

freeswitch.consoleLog("INFO", "agent_handler.lua: Starting for session " .. uuid .. "\n")

-- Start the audio stream
local metadata = json.encode({
  call_id = uuid,
  caller_id_number = session:getVariable("caller_id_number"),
  destination_number = session:getVariable("destination_number")
})
local bearer_token = 'Bearer ' .. session:getVariable('urai_api_key')
local headers = json.encode({
    Authorization = bearer_token
})
session:setVariable("STREAM_EXTRA_HEADERS", headers)

-- The metadata must be passed as a string with escaped quotes for the API command
local cmd_args = string.format("uuid_audio_stream %s start %s mono 16k '%s'", uuid, ws_url, metadata)
session:consoleLog("INFO", "agent_handler.lua: Executing command: uuid_audio_stream " .. cmd_args .. "\n")
local api = freeswitch.API()
local res = api:executeString(cmd_args)

if not string.find(res, "+OK") then
  freeswitch.consoleLog("ERROR", "agent_handler.lua: Failed to start audio stream: " .. (res or "pcall error") .. "\n")
  session:hangup()
  return
end

-- Use a non-blocking event consumer approach
local con = freeswitch.EventConsumer()
con:bind("custom", "mod_urai::play")

while session:ready() do
  local event = con:pop(1, 100)
  if event ~= nil then
      if event:getHeader("Event-Name")=="CUSTOM" and event:getHeader("Event-Subclass")=="mod_urai::play" then
          local event_uuid = event:getHeader("Unique-ID")
          -- uncomment for debugging
          -- freeswitch.consoleLog("INFO", "agent_handler.lua: Received playback event for " .. event_uuid .. " uuid - " .. uuid .. "\n")
          if event_uuid == uuid then
              local body = event:getBody()
              -- uncomment for debugging
              -- freeswitch.consoleLog("DEBUG", "agent_handler.lua: Playing " .. body .. " for " .. uuid .. "\n")
              session:execute("playback", body)
          end
      end
  end
  session:sleep(50)
end
