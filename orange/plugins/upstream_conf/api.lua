local BaseAPI = require("orange.plugins.base_api")
local common_api = require("orange.plugins.common_api")
local json = require("orange.utils.json")
local cjson = require('cjson')

local orange_db = require("orange.store.orange_db")
local utils = require("orange.utils.utils")

local api = BaseAPI:new("upstream-conf-api", 2)
local dao = require("orange.store.dao")

local store = context.store

local upstrem_dict = ngx.shared.upstream_conf

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


api:post("/upstream_conf/sync", function(store)
    return function(req, res, next)
        local load_success = dao.load_data_by_mysql(store, db_plugin)
        if load_success then
            local worker_ids = upstrem_dict:get_keys(1024)

            dao.upstream_conf_worker_sync_status()

            return res:json({
                success = true,
                msg = "succeed to load config from store"
            })
        else
            ngx.log(ngx.ERR, "error to load plugin[" .. db_plugin .. "] config from store")
            return res:json({
                success = false,
                msg = "error to load config from store"
            })
        end
    end
end)

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

        -- 编辑模式
        local editMode = orange_db.get( db_plugin .. ".editMode")
        if editMode then
            rst.data['editMode'] = 1
        else
            rst.data['editMode'] = 0
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

-- 开启禁用编辑模式
api:post('/upstream_conf/edit',function(store)
    return function(req, res, next)
        local editMode = req.body.curEditMode
        if tonumber(editMode) == nil or not ( tonumber(editMode) == 0 or tonumber(editMode) == 1 ) then
            return res:json({
                success = false,
                data = "editModule is error"
            })
        end

        local editStatus = true
        if tonumber(editMode) == 0 then
            editStatus = false
        end

        ngx.log(ngx.ERR,'curr edit module:',editStatus)

        local result, err, forcible = orange_db.set( db_plugin .. ".editMode",editStatus)
        if not result or err then
            return res:json({
                success = false,
                data = "editModule failed " .. (err or '')
            })
        end
        return res:json({
            success = true,
            data = "success change edit mode"
        })
    end
end)


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

            -- 同时需要写到 orange db模块中
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

            local success, err, forcible = orange_db.set_json(db_plugin .. ".upstream", curl_block)
            if err or not success then
                ngx.log(ngx.ERR, "update local plugin[" .. db_plugin .. "] upstream error, err:", err)
                return false
            end

            dao.upstream_conf_worker_sync_status(db_plugin)

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
