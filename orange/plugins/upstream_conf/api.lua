local BaseAPI = require("orange.plugins.base_api")
local common_api = require("orange.plugins.common_api")
local json = require("orange.utils.json")
local cjson = require('cjson')

local orange_db = require("orange.store.orange_db")
local utils = require("orange.utils.utils")

local api = BaseAPI:new("upstream-conf-api", 2)

local store = context.store

local upstream = require "ngx.upstream"
local get_upstreams = upstream.get_upstreams
local get_servers   = upstream.get_servers

local db_type = 'customer_data'
local db_plugin = 'upstream_conf'

api:merge_apis(common_api("upstream_conf"))


local function get_db_upstream_blocks(upstream_key)
    -- 更新成功, 需要更新数据库
    local blocks, err = store:query({
        sql = "select * from upstream_conf where `key` in ( '" .. upstream_key ..  "' ) and `type`=?",
        params = {db_type}
    })
    return blocks, err
end

local function delete_db_upstream_blocks(upstream_key)
    local delete_result = store:delete({
        sql = "delete from upstream_conf where `key` in ( '" .. upstream_key .. "' ) and `type`=?",
        params = { db_type }
    })
    return delete_result
end

local function insert_db_upstream_blocks( upstream_key, cur_block )
    local ok ,err = store:insert({
        sql = "insert into upstream_conf (`key`, `value`, `type`, `op_time`) values(?,?,?,now())",
        params = { upstream_key , json.encode(cur_block), db_type }
    })
    return ok, err
end

local function update_db_upstream_blocks(db_id , cur_block)
    local ok , err = store:update({
        sql = "update upstream_conf set value = ? , op_time = now() where id = ?",
        params = { json.encode(cur_block) , db_id }
    })
    return ok, err
end

-- 是否启用
api:get("/upstream_conf/status", function(store)
    return function(req, res, next)
        local rst = {
            success = true,
            data = {}
        }
        rst.data['upstreams'] = get_upstreams()
        local enable =  orange_db.get( db_plugin .. ".enable")
        if enable then
            rst.data['enable'] = 1
        else
            rst.data['enable'] = 0
        end
        res:json(rst)
    end
end)


-- 根据upstream block获取server列表信息
api:get("/upstream_conf/upstream", function(store)
    return function(req, res, next)
        local up_name = req.query.name;

        if not up_name or type(up_name) ~= "string" or #up_name < 1 then
            rst.success = false
            rst.data = "upstream name is error"
            return res:json({
                success = false,
                data = "upstream name is error"
            })
        else
            local primary_srvs, err = upstream.get_primary_peers(up_name)
            local backup_servs, err = upstream.get_backup_peers(up_name)
            if primary_srvs and backup_servs then
                local all_servs = {}
                all_servs['primary'] = primary_srvs;
                all_servs['backup'] = backup_servs;
                all_servs['id'] = up_name
                res:json({
                    success = true,
                    data = all_servs
                })
            else
                res:json({
                    success = false,
                    data = "upstream name get servers failed " .. ( err or '')
                })
            end
        end
    end
end)

--
---- 更新单个 upstream
--api:post('/upstream_conf/upstream', function(store)
--    return function(req, res, next)
--        local srv_name = req.query.srv_name
--        local up_name = req.query.upstream
--        local is_backup = req.query.is_backup
--        local id = req.query.id
--        local status = req.query.status
--        if not up_name or type(up_name) ~= "string" or #up_name < 1 then
--            return res:json({
--                success = false,
--                data = "upstream name is error"
--            })
--        end
--
--        if not srv_name or type(srv_name) ~= "string" or #srv_name < 1 then
--            return res:json({
--                success = false,
--                data = "srv_name name is error"
--            })
--        end
--
--        if not( type(is_backup) == "boolean" or tostring(is_backup) == "true" or tostring(is_backup) == "false" ) then
--            return res:json({
--                success = false,
--                data = "is_backup must boolean"
--            })
--        end
--
--        if not ( (type(id) == "number" and id >= 0 ) or (tonumber(id) ~= nil and tonumber(id) >= 0 ) ) then
--            return res:json({
--                success = false,
--                data = "id must number"
--            })
--        end
--
--        if not( type(status) == "boolean" or tostring(status) == "true" or tostring(status) == "false" ) then
--            return res:json({
--                success = false,
--                data = "is_backup must boolean"
--            })
--        end
--
--        local cur_is_backup = false
--        local srvs, err
--        if tostring(is_backup) == "true" then
--            cur_is_backup = true
--            srvs, err = upstream.get_backup_peers(up_name)
--        else
--            cur_is_backup = false
--            srvs, err = upstream.get_primary_peers(up_name)
--        end
--
--        if srvs and not err then
--            local cur_srvs = {}
--            for _ , v in pairs(srvs) do
--                cur_srvs[tostring(v.id)] = v
--            end
--            if cur_srvs[tostring(id)] then
--                local peer = cur_srvs[tostring(id)]
--                if peer['name'] == srv_name then
--                    local pok, perr = upstream.set_peer_down(up_name, cur_is_backup, id, status)
--                    if pok and not perr then
--                        -- save config to database
--                        -- save config to shared
--
--                        local query_data , err = get_db_upstream_blocks(up_name)
--                        if not err and query_data and type(query_data) == "table" then
--                            peer.id = up_name
--                            peer.time = utils.now()
--                            if #query_data == 0 then
--                                -- insert
--                                local ok, err = insert_db_upstream_blocks(up_name,peer)
--                                if err then
--                                    ngx.log(ngx.ERR,'insert_db_upstream_blocks failed, err:', err,
--                                        ',upstream:',up_name,
--                                        ',peer:',json.encode(peer)
--                                    )
--                                end
--                            else
--                                local cur_id = query_data[1].id
--                                local ok, err = update_db_upstream_blocks(cur_id,peer)
--                            end
--                        end
--
--                        return res:json({
--                            success = true,
--                            data = "success"
--                        })
--                    else
--
--                        return res:json({
--                            success = false,
--                            data = "set_peer_down faield," .. ( perr or '' )
--                        })
--                    end
--                else
--                    return res:json({
--                        success = false,
--                        data = "server name not exists"
--                    })
--                end
--            else
--                return res:json({
--                    success = false,
--                    data = "server id not exists"
--                })
--            end
--        else
--            return res:json({
--                success = false,
--                data = "upsteamname not exists"
--            })
--        end
--    end
--end)



-- 批量更新
api:post('/upstream_conf/upstream',function(store)
    return function(req, res, next)
        local up_name = req.query.name
        if not up_name or type(up_name) ~= "string" or #up_name < 1 then

            return res:json({
                success = false,
                data = "upstream name is error"
            })
        end

        local servers = req.body
        local primarys = servers['primary']
        local backups = servers['backup']

        local tmp_primary = {}
        for _, v in pairs(primarys) do
            tmp_primary[v.id] = v
        end

        local tmp_backup = {}
        for _, v in pairs(backups) do
            tmp_backup[v.id] = v
        end

        -- 先校验所有数据,再修改
        local primary_srvs, err = upstream.get_primary_peers(up_name)
        if primary_srvs and not err then
            for _, v in pairs(primary_srvs) do
                local tx = tmp_primary[v.id]
                if tx and (tx.name ~= v.name or type(tx['down']) ~= 'boolean' ) then
                    return res:json({
                        success = false,
                        data = 'primary name not eq, id:' .. v.id .. ',name:' .. tx.name
                    })
                end
            end
        end

        local backup_srvs, err = upstream.get_backup_peers(up_name)
        if backup_srvs and not err then
            for _, v in pairs(backup_srvs) do
                local tx = tmp_backup[v.id]
                if tx and (tx.name ~= v.name or type(tx['down']) ~= 'boolean' ) then
                    return res:json({
                        success = false,
                        data = 'backup name not eq, id:' .. v.id .. ',name:' .. tx.name
                    })
                end
            end
        end

        -- 对已经存在的数据,进行更新状态
        if primary_srvs and not err then
            for _, v in pairs(primary_srvs) do
                local tx = tmp_primary[v.id]
                if tx and tx.name == v.name then
                    if v['down'] == nil or tx['down'] ~= v['down'] then
                        local pok, perr = upstream.set_peer_down(up_name, false, v.id, tx['down'])
                        if not pok or perr then
                            return res:json({
                                success = false,
                                data = string.format('primary %s name id:%d update faield', up_name, v.id)
                            })
                        end
                    end
                end
            end
        end

        if backup_srvs and not err then
            for _, v in pairs(backup_srvs) do
                local tx = tmp_backup[v.id]
                if tx and tx.name == v.name then
                    if v['down'] == nil or tx['down'] ~= v['down'] then
                        local pok, perr = upstream.set_peer_down(up_name, true, v.id, tx['down'])
                        if not pok or perr then
                            return res:json({
                                success = false,
                                data = string.format('backup %s name id:%d update faield', up_name, v.id)
                            })
                        end
                    end
                end
            end
        end

        -- 更新成功, 需要更新数据库
        local blocks, err = get_db_upstream_blocks(up_name)
        if blocks and type(blocks) == "table" then
            -- 数据库不存在
            local insert_flag = false
            if #blocks == 1 then
                -- 存在则更新
                insert_flag = false
            elseif #blocks == 0 then
                insert_flag = true
            end

            primary_srvs, err = upstream.get_primary_peers(up_name)
            if err then
                ngx.log(ngx.ERR,'try get_primary_peers failed,',err)
            end

            backup_srvs, err = upstream.get_backup_peers(up_name)
            if err then
                ngx.log(ngx.ERR,'try get_backup_peers failed,',err)
            end

            local opt_status = false
            -- 重新插入
            local curl_block = {}
            curl_block['primary'] = primary_srvs
            curl_block['backup'] = backup_srvs
            curl_block['id'] = up_name
            curl_block['time'] = utils.now()

            if insert_flag then
                -- insert
                local ok ,err = insert_db_upstream_blocks( up_name, curl_block)
                if not err then
                    opt_status = true
                else
                    ngx.log(ngx.ERR,'insert upstream_conf failed! err:', err)
                end
            else
                -- update
                local db_id = blocks[1].id
                local ok ,err = update_db_upstream_blocks(db_id, curl_block)
                if not err then
                    opt_status = true
                else
                    ngx.log(ngx.ERR,'update upstream_conf failed! db_id:' .. tostring(db_id)  .. ',err', err)
                end
            end

            if opt_status then
                return res:json({
                    success = true,
                    data = 'success'
                })
            else
                return res:json({
                    success = false,
                    data = 'update upstream info failed, please check nginx error log'
                })
            end
        else
            return res:json({
                success = false,
                data = 'query databse failed, err:' .. ( err or '')
            })
        end
    end
end)


return api
