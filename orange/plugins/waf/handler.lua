local pairs = pairs
local ipairs = ipairs
local orange_db = require("orange.store.orange_db")
local judge_util = require("orange.utils.judge")
local extractor_util = require("orange.utils.extractor")
local handle_util = require("orange.utils.handle")
local BasePlugin = require("orange.plugins.base_handler")
local stat = require("orange.plugins.waf.stat")

local waf_freq = ngx.shared.waf_freq

-- 创建dict里面使用的key
local function build_check_key(rule_id,check_field)
    return string.format("waf:%s:%s",rule_id,check_field)
end


local dict_key_ttl = 1800

----  cur_key    检查的key
----  max_count  最大请求次数
----  time_unit  每检查执行周期
----  forbidden_time  禁止访问时间

local  function waf_proc_filter(cur_key, max_count, time_unit, forbidden_time )
    local cur_time = ngx.time()
    local client_info,err = waf_freq:get(cur_key)
    local key_ttl = dict_key_ttl
    ---- key 
    ---- val :  firstTimestamp|checkTimestamp|checkValue
    ----        10            |     10       |  x 
    local filter_status  =  false
    if client_info and #tostring(client_info) >= 23  then
        local first_time = string.sub(client_info,1,10)
        local prv_time    = tonumber(string.sub(client_info,12,21)) or 0
        local prv_value   = tonumber(string.sub(client_info,23) ) or 0

        ---- 当前时间减去之前时间,小于单位时间间隔
        if cur_time - prv_time  <= time_unit then
            ---- 超出阈值
            if prv_value >= max_count then
                -- find filter 
                ngx.log(ngx.WARN,string.format("key:[%s] count:%s waf filtered in time-unit",cur_key,max_count))
                filter_status = true
            else
                local succ, err, forcible = waf_freq:set(cur_key,string.format("%s|%s|%s",first_time,prv_time,prv_value+1))
                if not succ then
                    ngx.log(ngx.ERR,string.format("%s %s set dict failed",cur_key,err))
                end
            end
        else
            ---- 检查时间超过检查周期,需要判断,是否需要冻结一段时间
            if cur_time - prv_time <= forbidden_time  and  prv_value >= max_count then
                ngx.log(ngx.WARN,string.format("key:[%s] count:%s waf filtered in forbidden-time",cur_key,max_count))
                filter_status = true
            else
                waf_freq:set(cur_key,string.format("%s|%s|%s",first_time,cur_time,1),key_ttl)
            end

        end
    else
        -- first time save to dict
        -- and checkValue is 1 
        local succ, err, forcible = waf_freq:set(cur_key,string.format("%s|%s|%s",cur_time,cur_time,1),key_ttl)
        if not succ then
            ngx.log(ngx.ERR,string.format("%s %s first set dict failed",cur_key,err))
        end
    end
    return filter_status
end

local function filter_rules(sid, plugin, ngx_var_uri)
    local rules = orange_db.get_json(plugin .. ".selector." .. sid .. ".rules")
    if not rules or type(rules) ~= "table" or #rules <= 0 then
        return false
    end

    for i, rule in ipairs(rules) do
        if rule.enable == true then
            -- judge阶段
            local pass = judge_util.judge_rule(rule, plugin)

            -- extract阶段
            local variables = extractor_util.extract_variables(rule.extractor)

            -- handle阶段
            if pass then
                local handle = rule.handle
                if handle.stat == true then
                    local key = rule.id -- rule.name .. ":" .. rule.id
                    stat.count(key, 1)
                end

                if handle.perform == 'allow' then
                    if handle.log == true then
                        ngx.log(ngx.INFO, "[WAF-Pass-Rule] ", rule.name, " uri:", ngx_var_uri)
                    end
                else
                    local rule_lam = loadstring(handle.rule_lambda )
                    if type( rule_lam ) == "function" then
                        ---- 需要判断逻辑
                        -- RULE_ID:
                        -- HTTP_HEADER:[XX]
                        local req_check_field    = rule_lam()

                        ngx.log(ngx.INFO,string.format("[WAF***] rule_id:%s req_check_field:%s", 
                                        handle.rule_id,req_check_field ))


                        local cur_key = build_check_key(handle.rule_id,req_check_field)

                        ngx.log(ngx.INFO,string.format("[WAF***] check_key:%s " , cur_key )) 


                        local ret = waf_proc_filter(cur_key, handle.rule_frequency , handle.rule_time_unit, (handle.forbidden_min * 60) )
                        if type(ret) == "boolean" then
                            if ret == true then
                                if handle.log == true then
                                    ngx.log(ngx.INFO, "[WAF-Forbidden-Rule] ", rule.name, " uri:", ngx_var_uri)
                                end
                                ngx.exit(tonumber(handle.code or 403))
                                return true
                            end
                        end
                    else
                        ngx.log(ngx.ERR, string.format("[WAF-LAMBDA] is not function--:%s,rule_lambda:%s",type(rule_lam),handle.rule_lambda))
                    end
                end
            end
        end
    end

    return false
end


local WAFHandler = BasePlugin:extend()
WAFHandler.PRIORITY = 2000

function WAFHandler:new(store)
    WAFHandler.super.new(self, "waf-plugin")
    self.store = store
end

function WAFHandler:access(conf)
    WAFHandler.super.access(self)

    local enable = orange_db.get("waf.enable")
    local meta = orange_db.get_json("waf.meta")
    local selectors = orange_db.get_json("waf.selectors")
    local ordered_selectors = meta and meta.selectors

    if not enable or enable ~= true or not meta or not ordered_selectors or not selectors then
        return
    end

    local ngx_var_uri = ngx.var.uri
    for i, sid in ipairs(ordered_selectors) do
        ngx.log(ngx.INFO, "==[WAF][PASS THROUGH SELECTOR:", sid, "]")
        local selector = selectors[sid]
        if selector and selector.enable == true then
            local selector_pass
            if selector.type == 0 then -- 全流量选择器
                selector_pass = true
            else
                selector_pass = judge_util.judge_selector(selector, "waf")-- selector judge
            end

            if selector_pass then
                if selector.handle and selector.handle.log == true then
                    ngx.log(ngx.INFO, "[WAF][PASS-SELECTOR:", sid, "] ", ngx_var_uri)
                end

                local stop = filter_rules(sid, "waf", ngx_var_uri)
                if stop then -- 不再执行此插件其他逻辑
                    return
                end
            else
                if selector.handle and selector.handle.log == true then
                    ngx.log(ngx.INFO, "[WAF][NOT-PASS-SELECTOR:", sid, "] ", ngx_var_uri)
                end
            end

            -- if continue or break the loop
            if selector.handle and selector.handle.continue == true then
                -- continue next selector
            else
                break
            end
        end
    end

end

return WAFHandler
