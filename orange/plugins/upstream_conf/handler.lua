local BasePlugin = require("orange.plugins.base_handler")
local orange_db = require("orange.store.orange_db")
local json = require("orange.utils.json")

local plugin_name = 'upstream_conf'

local upstream = require "ngx.upstream"
local get_upstreams = upstream.get_upstreams
local get_servers   = upstream.get_servers


local UpstreamConfHandler = BasePlugin:extend()

UpstreamConfHandler.PRIORITY = 2000

function UpstreamConfHandler:new()
    UpstreamConfHandler.super.new(self, "upstream-conf-plugin")
end

local function update_upstream_conf()
    local up_conf = orange_db.get_json(plugin_name .. ".upstream")

    ngx.log(ngx.WARN,'test1', type(up_conf))

    if up_conf and type(up_conf) == "table" then
--        ngx.log(ngx.WARN,'test2')

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
                            if status == nil or type(status) ~= "boolean" then
                                status = false
                            end
--                            ngx.log(ngx.WARN,'-- update server status:',up_name,',id:', ng_perr.id ,',name:', ng_perr['name'] ,',down status:',status)
                            local pok, perr = upstream.set_peer_down(up_name, false, ng_perr.id, status)
                            if perr then
                                ngx.log(ngx.ERR,'primary set_peer_down failed err:',perr,',up:',up_name,',id:',ng_perr.id,',status:',status)
--                            else
--                                ngx.log(ngx.WARN,'***updatd success')
                            end
                        end
                    end
--                else
--                    ngx.log(ngx.WARN,'upstream:', up_name,' not exists primary servers')
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
                            if status == nil or type(status) ~= "boolean" then
                                status = false
                            end
                            local pok, perr = upstream.set_peer_down(up_name, true, ng_perr.id, status)
                            if perr then
                                ngx.log(ngx.ERR,'backup set_peer_down failed err:',perr,',up:',up_name,',id:',ng_perr.id,',status:',status)
--                            else
--                                ngx.log(ngx.WARN,'***updatd success')
                            end
                        end
                    end
--                else
--                    ngx.log(ngx.WARN,'upstream:', up_name,' not exists backup servers')
                end
            end
        end
    end
end

function UpstreamConfHandler:init_worker()
    update_upstream_conf()
    --
    local delay = 3  -- in seconds
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

function UpstreamConfHandler:log(conf)
    local worker_id = ngx.worker.id()
    ngx.log(ngx.WARN,tostring(worker_id),':---UpstreamConfHandler---log')
--    stat.log()
end

return UpstreamConfHandler
