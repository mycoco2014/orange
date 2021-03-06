local BasePlugin = require("orange.plugins.base_handler")
local orange_db = require("orange.store.orange_db")
local json = require("orange.utils.json")

local plugin_name = 'upstream_conf'

local upstrem_dict = ngx.shared.upstream_conf

local upstream = require "ngx.upstream"
local get_upstreams = upstream.get_upstreams
local get_servers   = upstream.get_servers

-- 定时同步时间为5秒
local MAX_DELAY = 5

local UpstreamConfHandler = BasePlugin:extend()

UpstreamConfHandler.PRIORITY = 2000

function UpstreamConfHandler:new()
    UpstreamConfHandler.super.new(self, "upstream-conf-plugin")
end

local function get_worker_uniq()
    local cur_pid = ngx.worker.pid()
    return plugin_name .. ".workersync." .. tostring(cur_pid) .. ".status"
end

-- 更新最后同步时间
local function update_worker_uniq()
    local cur_pid = ngx.worker.pid()
    local update_key = plugin_name .. ".workersync." .. tostring(cur_pid) .. ".timestamp"
    orange_db.set(update_key,ngx.localtime())
end


-- 同步标志
local function init_worker_list()
    -- worker id 需要写入 列表
    -- 以及清理worker
    local worker_id = ngx.worker.pid()
    -- 设置进程id
    ngx.log(ngx.WARN,"add worker id to dict:", worker_id)
    upstrem_dict:set(tostring(worker_id),"1")
end


local function checker_worker_list()
    -- worker id 需要写入 列表
    -- 以及清理worker
    local worker_id = ngx.worker.pid()
    -- 设置进程id
    local ret = upstrem_dict:get(tostring(worker_id))
    if not ret then
        ngx.log(ngx.WARN,"get failed add worker id to dict:", worker_id)
        init_worker_list()
    end
end


local function update_upstream_conf()
    local worker_id = ngx.worker.pid()
    local enable = orange_db.get( plugin_name .. ".enable")
    if not enable then
        -- 插件未启用,不同步
--        ngx.log(ngx.WARN,"插件未启用:", worker_id)
        return
    end

    local editMode = orange_db.get( plugin_name .. ".editMode")
    if editMode then
        -- 当前为编辑模式,禁止从sharedict同步修改nginx进程配置
--        ngx.log(ngx.WARN,"当前为编辑模式,不同步数据:", worker_id)
        return
    end

    checker_worker_list()

    -- 检查同步标志
    local uniq_id = get_worker_uniq()
    local unsync = orange_db.get(uniq_id)
    if not unsync then
        -- 已经同步过了
--        ngx.log(ngx.WARN,"数据已经同步---", uniq_id,',unsync:',unsync)
        return
    end

    ngx.log(ngx.WARN,'****发现 worker需要更新配置,',uniq_id)

    -- 清理已经同步的标志
    -- 避免多次同步
    orange_db.set(uniq_id,false)

    local up_conf = orange_db.get_json(plugin_name .. ".upstream")

--    ngx.log(ngx.WARN,'test1,', type(up_conf))

    if up_conf and type(up_conf) == "table" then
        for key, db_upstream in pairs(up_conf) do
            local up_name = key
            local primary_srvs, err1 = upstream.get_primary_peers(up_name)
            local backup_servs, err2 = upstream.get_backup_peers(up_name)
            if err1 or err2 then
                ngx.log(ngx.ERR,'init get upstream block failed, primary err:', err1, ',backup err:', err2)
            else
                -- ok
                -- 以内存数据库为准
                if primary_srvs and type(primary_srvs) == "table" and #primary_srvs > 0 then
                    local db_primary = db_upstream['primary']
                    local db_tab = {}
                    for _ , db_peer in pairs(db_primary) do
                        db_tab[tostring(db_peer.id)] = db_peer
                    end
                    for _ , ng_perr in pairs(primary_srvs) do
                        local db_peer = db_tab[tostring(ng_perr.id)]
                        if db_peer and db_peer['name'] == ng_perr['name'] then
                            -- 数据库存在当前upstream block的id,且名称相同才更新
                            local status = db_tab[tostring(ng_perr.id)]['down']
                            if type(status) ~= "boolean" then
                                status = false
                            elseif status == nil then
                                status = true
                            end
                            local pok, perr = upstream.set_peer_down(up_name, false, ng_perr.id, status)
                            if perr then
                                ngx.log(ngx.ERR,'primary set_peer_down failed err:',perr,',up:',up_name,',id:',ng_perr.id,',status:',status)
                            end
                        end
                    end
                end

                if backup_servs and type(backup_servs) == "table" and #backup_servs > 0 then
                    local db_backup = db_upstream['backup']
                    local db_tab = {}
                    for _ , db_peer in pairs(db_backup) do
                        db_tab[tostring(db_peer.id)] = db_peer
                    end
                    for _ , ng_perr in pairs(backup_servs) do
                        local db_peer = db_tab[tostring(ng_perr.id)]
                        if db_peer and db_peer['name'] == ng_perr['name'] then
                            -- 数据库存在当前upstream block的id,且名称相同才更新
                            local status = db_tab[tostring(ng_perr.id)]['down']
                            if type(status) ~= "boolean" then
                                status = false
                            elseif status == nil then
                                status = true
                            end
                            local pok, perr = upstream.set_peer_down(up_name, true, ng_perr.id, status)
                            if perr then
                                ngx.log(ngx.ERR,'backup set_peer_down failed err:',perr,',up:',up_name,',id:',ng_perr.id,',status:',status)
                            end
                        end
                    end
                end
            end
        end
    end

    update_worker_uniq()

end


-- 定时刷新时间间隔
function UpstreamConfHandler:init_worker()

    --
    init_worker_list()

    --
    local delay = MAX_DELAY  -- in seconds
    local new_timer = ngx.timer.at
    local log = ngx.log
    local ERR = ngx.ERR
    local check

    check = function(premature)
        if not premature then
            -- do the health check or other routine work
            update_upstream_conf()

            local ok, err = new_timer(delay, check)
            if not ok then
                log(ERR, "failed to create timer: ", err)
                return
            end
        end
    end

    local hdl, err = new_timer(delay, check)
    if not hdl then
        log(ERR, "failed to create timer: ", err)
        return
    end
end


--
--function UpstreamConfHandler:log(conf)
--end

return UpstreamConfHandler
