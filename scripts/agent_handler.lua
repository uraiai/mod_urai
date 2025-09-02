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
con:bind("custom", "mod_urai::message")

-- Instead of blocking the main thread, use a very short timeout and yield control
while session:ready() do
  local event = con:pop(1, 100)
  if event ~= nil then
      if event:getHeader("Event-Name")=="CUSTOM" and event:getHeader("Event-Subclass")=="mod_urai::play" then
          local event_uuid = event:getHeader("Unique-ID")
          if event_uuid == uuid then
              local body = event:getBody()
              session:execute("playback", body)
          end
      end
      if event:getHeader("Event-Name")=="CUSTOM" and event:getHeader("Event-Subclass")=="mod_urai::message" then
          local event_uuid = event:getHeader("Unique-ID")
          if event_uuid == uuid then
            local body = event:getBody()
            local obj, _pos, err = json.decode(body, 1, nil)
            if err then
              freeswitch.consoleLog("INFO", "agent_handler.lua: Unable to decode body for  " .. event_uuid .. " with message: " .. body .. "\n")
            else
                if obj['event']=='clear' then
                    local api = freeswitch.API()
                    local res = api:executeString("uuid_break " .. uuid .. " all")
                end
            end
          end
      end
  end
  session:sleep(50)  -- Sleep for 50ms to allow audio frame processing
end
