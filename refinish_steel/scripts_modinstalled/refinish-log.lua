-- refinish-log.lua
-- ==========================================
-- TOOL: LOG LINE COMPOSER
-- ==========================================
-- Formats a tagged log line. Nothing else.
--
-- ---- THE RULE THIS FILE EXISTS TO OBEY ----
-- Core never knows which modules exist, and core never decides what
-- a module's line means. The onus is on the MODULE to hand RM
-- correct information; RM's job is to carry it, not to work it out.
--
-- Two earlier attempts broke that, and both are worth naming so they
-- are not rebuilt:
--
--   1. A table of module names in refinish_steel, deriving tags at
--      the sink. Shipping a new module would have meant editing the
--      engine.
--   2. This file inferring TYPE by reading the module's prose for
--      the word FAILED. No module names in it, and still core doing
--      the module's declaring on its behalf. It lived on as
--      read_type(), a reader modules could elect to call while their
--      call sites were converted; every call site now states its TYPE,
--      and read_type() is gone.
--
-- So compose() asks for four tags and formats four tags. It does not
-- guess, and a caller that omits something gets told, not covered
-- for.
--
-- ---- THE GRAMMAR ----
--   SYSTEM SUBSYSTEM SUBJECT TYPE | body
--
-- Fixed columns are the point: every HIJACKER sits at the same x, so
-- the eye runs down one column instead of reading across lines.
--
--   SYSTEM     who owns this line. The module's own name.
--   SUBSYSTEM  which part of it.
--   SUBJECT    what it is about, and the correlation slot: JOB_2534,
--              CYCLE_3. A dash means not stated, which is honest. A
--              guessed correlation is worse than none.
--   TYPE       what kind of message. INFO, DETAIL, COMPLETE, YIELD,
--              WARNING, ERROR, FATAL, SUSPECT.
--
-- ---- WHAT AN OMITTED TAG DOES ----
-- It renders as UNTYPED or UNKNOWN, which the panel colours as a
-- fault-adjacent line. That is deliberate: an unconverted call site
-- should be visible so it gets converted, rather than quietly
-- absorbed by core guessing on its behalf. The whole reason eighteen
-- subsystems went uncoloured for months is that nothing was visibly
-- wrong.
--
-- USAGE. Every file that logs declares its own identity and funnels
-- every line through one function, TYPE first so a call site cannot
-- drop it unnoticed:
--
--   local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIJACKER'
--   local rlog = nil
--   pcall(function() rlog = reqscript('refinish-log') end)
--
--   local function log(typ, msg, subject)
--       if not _G.refinish_log_event then return end
--       local line
--       if rlog then
--           line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
--       else
--           -- The composer failed to load. Same grammar, unsanitised.
--           line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
--               tostring(subject or '-'), tostring(typ or 'UNTYPED'),
--               tostring(msg))
--       end
--       _G.refinish_log_event(line)
--   end
--
-- There is no level check in a funnel. Every line reaches the log on
-- disk, and the log panel's Log Detail setting decides what shows.
-- ==========================================

--@ module = true

-- ==========================================
-- NOTHING A MODULE DOES CAN BREAK THIS
-- ==========================================
-- A module can hand this a nil, a table, a number, a 400 character
-- string or a tag full of newlines. None of it may throw, and none
-- of it may produce a line that wrecks the columns for everybody
-- else.
--
-- So every input is coerced, sanitised and capped, and a tag that
-- survives none of that becomes BAD_TAG. The line still renders, the
-- module is visibly named as the source, and RM carries on. If your
-- jank does not process we bin it and keep going, rather than
-- failing in front of the user on your behalf.
local TAG_MAX  = 20
local BODY_MAX = 400

-- ==========================================
-- TAGS ARE SINGLE WORDS
-- ==========================================
-- Every run of non-alphanumeric collapses to one underscore, so
-- "HIDE STOCK" becomes HIDE_STOCK and "LOAD/RESTORE" becomes
-- LOAD_RESTORE. A space or a slash inside a tag would break the
-- fixed columns the whole scheme is read by.
local function tagify(s, dflt)
    if s == nil then return dflt end

    -- tostring can itself throw on a table with a hostile __tostring
    -- metamethod, which is exactly the kind of thing that must not
    -- take the log down.
    local ok, str = pcall(tostring, s)
    if not ok or str == nil or str == '' then return dflt end

    str = string.upper(str)
    str = str:gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if str == '' then return dflt end

    -- Capped, because one module passing a sentence as a tag would
    -- push every column on that line out of alignment and there is
    -- no way for the reader to tell whose fault that was.
    if #str > TAG_MAX then str = str:sub(1, TAG_MAX) end
    return str
end

-- ==========================================
-- COMPOSE
-- ==========================================
-- Formats. Does not infer. A missing tag becomes UNKNOWN or UNTYPED
-- rather than a guess, because a wrong tag is worse than an obviously
-- absent one: a guess looks right and is never corrected.
function compose(system, subsystem, subject, typ, msg)
    local ok, line = pcall(function()
        -- nil stays empty rather than becoming the string "nil",
        -- which would read as a real message.
        local body = ''
        if msg ~= nil then
            local okb, str = pcall(tostring, msg)
            if okb and str then body = str end
        end

        -- Newlines would split one entry into several and the extras
        -- would arrive with no tags at all, so they are flattened
        -- rather than passed through.
        body = body:gsub('[\r\n]+', ' ')
        if #body > BODY_MAX then
            body = body:sub(1, BODY_MAX) .. ' [truncated]'
        end

        return string.format('%s %s %s %s | %s',
            tagify(system,    'UNKNOWN'),
            tagify(subsystem, 'UNKNOWN'),
            tagify(subject,   '-'),
            tagify(typ,       'UNTYPED'),
            body)
    end)

    -- Even the sanitiser failing is survivable. Something always
    -- comes back, and it says where the problem was rather than
    -- vanishing.
    if ok and line then return line end
    return 'UNKNOWN BAD_TAG - ERROR | a log line could not be composed'
end

return _ENV
