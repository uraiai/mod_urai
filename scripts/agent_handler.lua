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

freeswitch.consoleLog("INFO", "agent_handler.lua: Call state: " .. session:getState() .. "\n")

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
session:consoleLog("INFO", "agent_handler.lua: uuid_audio_stream response: " .. (res or "nil") .. "\n")

if not string.find(res, "+OK") then
  freeswitch.consoleLog("ERROR", "agent_handler.lua: Failed to start audio stream: " .. (res or "pcall error") .. "\n")
  session:hangup()
  return
end

freeswitch.consoleLog("INFO", "agent_handler.lua: Audio stream started for " .. uuid .. "\n")

-- Use a non-blocking event consumer approach for clear events only
local con = freeswitch.EventConsumer()
con:bind("custom", "mod_urai::clear")
con:bind("custom", "mod_urai::message")

-- Main loop: poll for audio files and handle events
local api = freeswitch.API()

while session:ready() do
    -- Check for immediate clear events (non-blocking)
    local event = con:pop(1, 10)  -- Very short timeout
    if event ~= nil then
        if event:getHeader("Event-Name")=="CUSTOM" and event:getHeader("Event-Subclass")=="mod_urai::clear" then
            local event_uuid = event:getHeader("Unique-ID")
            if event_uuid == uuid then
                freeswitch.consoleLog("INFO", "agent_handler.lua: Received clear event, clearing queue and breaking current playback for " .. uuid .. "\n")
                -- Clear the audio queue immediately
                local clear_res = api:executeString("uuid_audio_stream " .. uuid .. " urai_clear_queue")
                freeswitch.consoleLog("DEBUG", "agent_handler.lua: Queue clear result: " .. (clear_res or "nil") .. "\n")
                -- Break any current playback
                local break_res = api:executeString("uuid_break " .. uuid .. " all")
                freeswitch.consoleLog("DEBUG", "agent_handler.lua: Break playback result: " .. (break_res or "nil") .. "\n")
            end
        end
        if event:getHeader("Event-Name")=="CUSTOM" and event:getHeader("Event-Subclass")=="mod_urai::message" then
            local event_uuid = event:getHeader("Unique-ID")
            freeswitch.consoleLog("DEBUG", "agent_handler.lua: Received message event for " .. event_uuid .. "\n")
            if event_uuid == uuid then
                local body = event:getBody()
                local obj, _pos, err = json.decode(body, 1, nil)
                if err then
                    freeswitch.consoleLog("DEBUG", "agent_handler.lua: Unable to decode message body: " .. body .. "\n")
                else
                    -- Handle transfer command
                    if obj['type']=='transfer' and obj['destination'] then
                        local dest = obj['destination']
                        freeswitch.consoleLog("INFO", "agent_handler.lua: Received transfer command to " .. dest .. " for " .. uuid .. "\n")
                        -- stop streaming and transfer
                        session:execute("transfer", dest .. " XML default")
                        api.executeString("uuid_audio_stream " .. uuid .. " stop")
                        -- After transfer, exit the loop
                        break
                    end
                    -- Handle transfer command
                    if obj['type']=='hangup' then
                        api.executeString("uuid_audio_stream " .. uuid .. " stop")
                        session:hangup()
                        -- After transfer, exit the loop
                        break
                    end
                    -- Handle any additional message-based clear events (fallback)
                    if obj['event']=='clear' or obj['type']=='clear' or obj['type']=='interrupt' then
                        freeswitch.consoleLog("INFO", "agent_handler.lua: Received clear command via message for " .. uuid .. "\n")
                        local clear_res = api:executeString("uuid_audio_stream " .. uuid .. " urai_clear_queue")
                        local break_res = api:executeString("uuid_break " .. uuid .. " all")
                    end
                end
            end
        end
    end

    -- Check for next audio file in queue
    local queue_res = api:executeString("uuid_audio_stream " .. uuid .. " queue_next_audio")
    if string.find(queue_res, "+OK") then
        local next_file = session:getVariable("urai_next_file")
        local queue_size = session:getVariable("urai_queue_size")

        if next_file and next_file ~= "" then
            freeswitch.consoleLog("INFO", "agent_handler.lua: Playing next queued file: " .. next_file .. " (queue size: " .. (queue_size or "unknown") .. ") for " .. uuid .. "\n")
            session:execute("playback", next_file)  -- Blocks until done or interrupted
            freeswitch.consoleLog("DEBUG", "agent_handler.lua: Finished playing: " .. next_file .. " for " .. uuid .. "\n")
        else
            -- No files in queue, sleep briefly
            session:sleep(100)
        end
    else
        freeswitch.consoleLog("ERROR", "agent_handler.lua: Failed to query queue: " .. (queue_res or "nil") .. "\n")
        session:sleep(100)
    end
end
