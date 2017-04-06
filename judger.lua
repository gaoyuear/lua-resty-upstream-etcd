local _M = {}

local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO
local new_timer = ngx.timer.at
local ngx_worker_id = ngx.worker.id
local ngx_worker_exiting = ngx.worker.exiting

local logger = require "lreu.logger"
local picker = require "lreu.picker"

local function info(...)
    log(INFO, "judger: ", ...)
end

local function warn(...)
    log(WARN, "judger: ", ...)
end

local function errlog(...)
    log(ERR, "judger: ", ...)
end

local function splitstr(str)
    local t = {}
    for i in str:gmatch("[^|]+") do
        t[#t+1] = i
    end
    return t
end

local function getUpstreamList()
    local dict = _M.storage
    local allname = dict:get("_allname")

    if not allname then
        warn("get nil upstream list")
        return nil
    end

    return splitstr(allname)
end

local function judge(report)
    return nil
end

local function peerFail(name, peer)
    local dict = _M.storage
    local key = "checkdown:" .. name .. ":" .. peer
    local ok, err = dict:set(key, true, _M.recover_after)
    if not ok then
        errlog("set peer fail error!", name, peer, err)
    else
        info("set peer fail.", name, peer)
    end
end

local function genReport(name)
    local report = {}
    local st = logger.report(name, nil, 5)
    for i = 1,#st.statistics do
        local peer = st.statistics[i]
        local total, errors = 0, 0
        for j = 1,#st.statistics[i].stat do
            total = total + st.statistics[i].stat[j].count
            if st.statistics[i].stat[j].code >= 400 then
                errors = errors + st.statistics[i].stat[j].count
            end
        end

        -- if a peer never process a request, may down.
        if total > 0 then
            err_rate = errors / total
            report[peer] = err_rate
        end
    end
    return report
end

local function check(premature, name)
    if premature or ngx_worker_exiting() then
        return
    end

    local report = genReport(name)
    local failed_peers = judge(report)

    for i = 1,#failed_peers do
        peerFail(name, failed_peers[i])
    end
 
    local ok, err = new_timer(_M.check_interval, check, name)
    if not ok then
        errlog("start time error: ", name, err)
    end
end

function _M.init(cfg)
    if ngx_worker_id() ~= 0 then
        return
    end

    -- use same storage with syncer
    -- 1. get all upstream name
    -- 2. put failed peers for picker
    if not cfg or not cfg.storage then
        errlog("configuration errors, no storage provide.")
        return
    else
        _M.storage = cfg.storage
    end

    if cfg.check_interval and cfg.check_interval >= 1 then
        _M.check_interval = cfg.check_interval
    else
        _M.check_interval = 5
    end

    -- default recover time is 60 seconds
    -- min recover time is 2*check_interval
    _M.recover_after = cfg.recover_after or 60
    if cfg.recover_after <= 2*_M.check_interval then
        _M.recover_after = 2*_M.check_interval
    end

    local us = getUpstreamList()
    for _, name in pairs(us) do

        local ok, err = new_timer(_M.check_interval, check, name)
        if ok then
            info("started: ", name, 
                 ",with interval: ", _M.check_interval, 
                 ",recover_after: ", _M.recover_after
                )
        else
            errlog("start time error: ", name, err)
        end
    end
end

return _M
