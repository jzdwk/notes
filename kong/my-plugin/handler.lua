-- 引入base plugin是可选的，也可以直接定义handler，比如像key-auth的定义
local BasePlugin = require "kong.plugins.base_plugin"
local MyPluginHandler = BasePlugin:extend()

-- 定义插件的优先级和版本，其中优先级的定义参考https://docs.konghq.com/2.2.x/plugin-development/custom-logic/#plugins-execution-order
MyPluginHandler.VERSION  = "1.0.0"
MyPluginHandler.PRIORITY = 15


-- Your plugin handler's constructor. If you are extending the
-- Base Plugin handler, it's only role is to instantiate itself
-- with a name. The name is your plugin name as it will be printed in the logs.
function MyPluginHandler:new()
  MyPluginHandler.super.new(self, "my-plugin")
end

-- http module下，handler总共有8个阶段可以嵌入自己的逻辑，具体阶段见下述代码。
-- 因为my-plugin将主要处理access阶段，所以其余阶段可以忽略

function MyPluginHandler:init_worker()
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.init_worker(self)

  -- Implement any custom logic here
end


function MyPluginHandler:preread(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.preread(self)

  -- Implement any custom logic here
end


function MyPluginHandler:certificate(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.certificate(self)

  -- Implement any custom logic here
end

function MyPluginHandler:rewrite(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.rewrite(self)

  -- Implement any custom logic here
end

--主要处理access阶段的功能，config参数为插件在配置时,config内的配置项
function MyPluginHandler:access(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.access(self)

  -- 以下为my-plugin的主要处理逻辑
  local start_time = os.clock()
  -- 通过官方的plugin development kit, 获取请求头，参考链接 https://docs.konghq.com/2.2.x/plugin-development/
  local headers = kong.request.get_headers()
  -- 调用核心的处理逻辑
  local ok = do_auth_n(headers, config)
  if not ok then
    kong.response.error(401,"undefined header in request")
  end
  kong.log.debug("[my-plugin] spend time : " .. os.clock() - start_time .. ".")
end

function MyPluginHandler:header_filter(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.header_filter(self)

  -- Implement any custom logic here
end

function MyPluginHandler:body_filter(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.body_filter(self)

  -- Implement any custom logic here
end

function MyPluginHandler:log(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  MyPluginHandler.super.log(self)

  -- Implement any custom logic here
end

-- This module needs to return the created table, so that Kong
-- can execute those functions.

-- 定义主要的处理逻辑，入参：
-- headers： http 请求头
-- config: 插件的config配置
function do_auth_n(headers,config)
  for k, v in pairs(headers) do
    kong.log.debug("[header]: " .. k .. "[header_value]: "..v)
    -- 遍历header table， 如果存在配置的header头以及对应的key，则返回
    if k == config.header_key and v == config.header_value then
        return true
    end
  end
  return false
end

return MyPluginHandler

