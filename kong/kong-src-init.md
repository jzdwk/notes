# kong init

从kong的start过程可以看到，在启动的nginx中，配置了nginx-kong.conf:
```shell

# 设置lua库路径，比如当lua中出现  require "abc.test",则根据path定义，替换问号并依次在./abc/test.lua；/abc/test/init.lua等路径查找文件
lua_package_path       './?.lua;./?/init.lua;;;;';
# 设置C编写的lua扩展模块的路径
lua_package_cpath      ';;;';

...省略

init_by_lua_block {
    Kong = require 'kong'
    Kong.init()
}
init_worker_by_lua_block {
    Kong.init_worker()
}
...

```

根据nginx-kong.conf设置的lua_path，其执行的kong代码位于路径`/usr/local/share/lua/5.1/kong`。

## kong init()

在openresty的init_by_lua_block阶段，首先调用了Kong.init()。

`Kong.init()`位于`/usr/local/share/lua/5.1/kong/init.lua`中，首先看一下`init.lua`中的变量定义：
```lua
local kong_global = require "kong.global"
-- 在_G中定义填写kong对象
_G.kong = kong_global.new() -- no versioned PDK for plugins for now

-- 引用kong的各个模块
local DB = require "kong.db"
local dns = require "kong.tools.dns"
local utils = require "kong.tools.utils"
local lapis = require "lapis"
local runloop = require "kong.runloop.handler"
local clustering = require "kong.clustering"
local singletons = require "kong.singletons"
local declarative = require "kong.db.declarative"
local ngx_balancer = require "ngx.balancer"
local kong_resty_ctx = require "kong.resty.ctx"
local certificate = require "kong.runloop.certificate"
local concurrency = require "kong.concurrency"
local cache_warmup = require "kong.cache_warmup"
local balancer_execute = require("kong.runloop.balancer").execute
local kong_error_handlers = require "kong.error_handlers"
local migrations_utils = require "kong.cmd.utils.migrations"
local go = require "kong.db.dao.plugins.go"

-- 对lua_ngx的封装
local kong             = kong
local ngx              = ngx
local now              = ngx.now
local update_time      = ngx.update_time
local var              = ngx.var
local arg              = ngx.arg
local header           = ngx.header
local ngx_log          = ngx.log
local ngx_ALERT        = ngx.ALERT
local ngx_CRIT         = ngx.CRIT
local ngx_ERR          = ngx.ERR
local ngx_WARN         = ngx.WARN
local ngx_INFO         = ngx.INFO
local ngx_DEBUG        = ngx.DEBUG
local subsystem        = ngx.config.subsystem
local type             = type
local error            = error
local ipairs           = ipairs
local assert           = assert
local tostring         = tostring
local coroutine        = coroutine
local get_last_failure = ngx_balancer.get_last_failure
local set_current_peer = ngx_balancer.set_current_peer
local set_timeouts     = ngx_balancer.set_timeouts
local set_more_tries   = ngx_balancer.set_more_tries
local TTL_ZERO         = { ttl = 0 }


local declarative_entities
local schema_state


local stash_init_worker_error
local log_init_worker_errors
```
继续看init的实现：
```lua
function Kong.init()
  --清空在nginx-kong.conf中定义的共享字典内存
  reset_kong_shm()

  -- special math.randomseed from kong.globalpatches not taking any argument.
  -- Must only be called in the init or init_worker phases, to avoid
  -- duplicated seeds.
  -- 定义随机数种子，优先使用 OpenSSL 生成的种子，如果失败了再用 ngx.now()*1000 + ngx.worker.pid() 替代
  math.randomseed()
  
  local pl_path = require "pl.path"
  local conf_loader = require "kong.conf_loader"

  -- check if kong global is the correct one
  ...
  -- 从/usr/local/kong目录下读取.kong_env文件，.kong_env在kong start时，根据kong.conf生成	
  -- retrieve kong_config
  local conf_path = pl_path.join(ngx.config.prefix(), ".kong_env")
  
  --调用conf_loader即为kong.conf_loader，它返回了一个table，并设置了元表__call方法，因此相当于直接调用__call中定义的函数
  local config = assert(conf_loader(conf_path, nil, { from_kong_env = true }))
```
这里的`assert(v,[message])`函数用于捕捉异常并打印错误，当v返回false,nil时，打印message。https://www.runoob.com/lua/lua-error-handling.html

### conf_loader

conf_loader主要进行kong.conf的配置加载，并针对自定义配置进行处理。进入kong.conf_loader,即文件conf_loader.lua
```lua
--省略...
--__call调用了load函数
return setmetatable({
  load = load,

  load_config_file = load_config_file,

  add_default_path = function(path)
    DEFAULT_PATHS[#DEFAULT_PATHS+1] = path
  end,

  remove_sensitive = function(conf)
    local purged_conf = tablex.deepcopy(conf)

    for k in pairs(CONF_SENSITIVE) do
      if purged_conf[k] then
        purged_conf[k] = CONF_SENSITIVE_PLACEHOLDER
      end
    end

    return purged_conf
  end,
}, {
  -- __call函数调用处
  __call = function(_, ...)
    return load(...)
  end,
})
```
可看到其主要做了6件事，包括：
- 加载/合并kong.conf基本的所有配置
- 处理kong插件配置
- 监听配置
- 头配置
- 文件路径配置
- kong自身文件目录配置

1. **kong conf初始化**
```lua
-- load函数实现，其中根据init的调用，path=conf_path, custom_conf=nil, opts = { from_kong_env = true }
local function load(path, custom_conf, opts)
  opts = opts or {}

  ------------------------
  -- Default configuration
  ------------------------

  -- load defaults, they are our mandatory base
  -- 加载默认配置，所有的默认项位于/kong/templates/kong_defaults.lua
  local s = pl_stringio.open(kong_default_conf)
  local defaults, err = pl_config.read(s, {
    smart = false,
    list_delim = "_blank_" -- mandatory but we want to ignore it
  })
  s:close()
  ...

  ---------------------
  -- Configuration file
  ---------------------
  -- 如果用户定义的自己的conf，则读取
  local from_file_conf = {}
  if path and not pl_path.exists(path) then
    -- file conf has been specified and must exist
    return nil, "no file at: " .. path
  end
  --如果没定义，读取默认路径
  if not path then
    for _, default_path in ipairs(DEFAULT_PATHS) do
      ...
	  if pl_path.exists(default_path) then
        path = default_path
        break
      end
      ...
    end
  end
  -- 读定义值到from_file_conf
  if not path then
    -- still no file in default locations
    ...
  else
    ...
    from_file_conf = load_config_file(path)
  end

  --将默认conf和自定义项进行合并，首先根据opts参数，处理环境变量，环境变量的值覆盖默认，赋值给user_conf，然后自定义覆盖user_conf，最终返回conf
  -----------------------
  -- Merging & validation
  -----------------------
  ...
  --具体实现省略
  -- merge user_conf with defaults
  local conf = tablex.pairmap(overrides, defaults,
                              { defaults_only = true },
                              user_conf)
  -- validation check
  ...
  conf = tablex.merge(conf, defaults) -- intersection (remove extraneous properties)

  --处理conf.nginx_main_user / conf.nginx_user ,如果指明nobody 置nil
  do
    -- nginx 'user' directive
    local user = utils.strip(conf.nginx_main_user):gsub("%s+", " ")
    if user == "nobody" or user == "nobody nobody" then
      conf.nginx_main_user = nil
    end

    local user = utils.strip(conf.nginx_user):gsub("%s+", " ")
    if user == "nobody" or user == "nobody nobody" then
      conf.nginx_user = nil
    end
  end
  -- 处理nginx_XXX_directives,XXX包括main/events/http/upstream/proxy/status等
  -- 以DYNAMIC_KEY_NAMESPACES其中的一项：
  --[[   
  {
    injected_conf_name = "nginx_main_directives",
    prefix = "nginx_main_",
    ignore = EMPTY,
  } nginx_main_directives举例 ]]-- 
  do
    local injected_in_namespace = {}
    -- nginx directives from conf
	-- 读取项为injected_conf_name = "nginx_main_directives"的表
    for _, dyn_namespace in ipairs(DYNAMIC_KEY_NAMESPACES) do
      -- 将nginx_main_directives记录为true，写入injected_in_namespace
	  injected_in_namespace[dyn_namespace.injected_conf_name] = true
	  -- 遍历conf，如果conf中的项不在injected_in_namespace中，并且匹配到了nginx_main_(.+)，并且没有被DYNAMIC_KEY_NAMESPACES对应的项配置为ignore
	  -- 将其加入directives表，其中name=conf中的key, value为对应值
	  -- 比如conf中定义了nginx_main_abc=abc，那么就可以写入directives
      local directives = parse_nginx_directives(dyn_namespace, conf,
                                               injected_in_namespace)
	  -- 在conf中写入，比如conf[nginx_main_directives] = {name = nginx_main_abc, value = abc}
      conf[dyn_namespace.injected_conf_name] = setmetatable(directives,
                                                            _nop_tostring_mt)
    end

    -- TODO: Deprecated, but kept for backward compatibility.
    for _, dyn_namespace in ipairs(DEPRECATED_DYNAMIC_KEY_NAMESPACES) do
      if conf[dyn_namespace.injected_conf_name] then
        conf[dyn_namespace.previous_conf_name] = conf[dyn_namespace.injected_conf_name]
      end
    end
  end

  --所有conf项排序并log打印  实现省略
  ...
```
2. **plugin配置** 

```lua
  -----------------------------
  -- Additional injected values
  -----------------------------
  do
    -- merge plugins 将自定义plugins和内置plguins都写入表plugins
    local plugins = {}
    -- conf中的plugins配置
    if #conf.plugins > 0 and conf.plugins[1] ~= "off" then
      for i = 1, #conf.plugins do
        local plugin_name = pl_stringx.strip(conf.plugins[i])

        if plugin_name ~= "off" then
		  -- 如果是bundled，从/kong/constants.lua的plugins中加载,并在pluginx中置true
          if plugin_name == "bundled" then
            plugins = tablex.merge(constants.BUNDLED_PLUGINS, plugins, true)
          else
		  -- 否则，配置自定义，比如plugins[my-plugins]=true
            plugins[plugin_name] = true
          end
        end
      end
    end
    --配置loaded_plugins为plguins表,添加__tostring元方法
    conf.loaded_plugins = setmetatable(plugins, _nop_tostring_mt)
  end

  -- 
  -- injected 处理监控插件prometheus
  if conf.loaded_plugins["prometheus"] then
    -- 加载conf中的nginx_http_directives相关项
	-- 如果没有，则增加共享内存配置lua_shared_dict，包括prometheus_metrics和stream_prometheus_metrics
    local http_directives = conf["nginx_http_directives"]
    local found = false
    ...
	-- 实现省略
```
3. **kong 监听配置**
```lua
  do
    local http_flags = { "ssl", "http2", "proxy_protocol", "deferred",
                         "bind", "reuseport", "backlog=%d+" }
    local stream_flags = { "ssl", "proxy_protocol", "bind", "reuseport",
                           "backlog=%d+" }

    -- extract ports/listen ips 
	-- 设置7层和4层的监听配置，包括proxy/admin/status
	-- 7层proxy 和 ssl，下同
    conf.proxy_listeners, err = parse_listeners(conf.proxy_listen, http_flags)
    ...
    setmetatable(conf.proxy_listeners, _nop_tostring_mt)
    conf.proxy_ssl_enabled = false
    for _, listener in ipairs(conf.proxy_listeners) do...end
	-- 4层proxy
    conf.stream_listeners, err = parse_listeners(conf.stream_listen, stream_flags)
    ...
    setmetatable(conf.stream_listeners, _nop_tostring_mt)
    conf.stream_proxy_ssl_enabled = false
    for _, listener in ipairs(conf.stream_listeners) do...end
    -- 7层admin
    conf.admin_listeners, err = parse_listeners(conf.admin_listen, http_flags)
    ...
    setmetatable(conf.admin_listeners, _nop_tostring_mt)
    conf.admin_ssl_enabled = false
    for _, listener in ipairs(conf.admin_listeners) do...end
    -- 7层status
    conf.status_listeners, err = parse_listeners(conf.status_listen, { "ssl" })
    ...
    setmetatable(conf.status_listeners, _nop_tostring_mt)
    -- 7层cluster
    conf.cluster_listeners, err = parse_listeners(conf.cluster_listen, http_flags)
    ...
    setmetatable(conf.cluster_listeners, _nop_tostring_mt)
  end
```
4. **代理后的http头配置**
```lua
  -- 被kong代理的后端服务，在http请求头会加入kong相关的头信息，比如 "X-Consumer-Username": "testgxl",等在此处配置可用的headers
  do
    -- load headers configuration
    local enabled_headers = {}
    for _, v in pairs(HEADER_KEY_TO_NAME) do
      enabled_headers[v] = false
    end
    if #conf.headers > 0 and conf.headers[1] ~= "off" then
      for _, token in ipairs(conf.headers) do
        if token ~= "off" then
          enabled_headers[HEADER_KEY_TO_NAME[string.lower(token)]] = true
        end
      end
    end
    if enabled_headers.server_tokens then
      enabled_headers[HEADERS.VIA] = true
      enabled_headers[HEADERS.SERVER] = true
    end
    if enabled_headers.latency_tokens then
      enabled_headers[HEADERS.PROXY_LATENCY] = true
      enabled_headers[HEADERS.RESPONSE_LATENCY] = true
      enabled_headers[HEADERS.ADMIN_LATENCY] = true
      enabled_headers[HEADERS.UPSTREAM_LATENCY] = true
    end
    conf.enabled_headers = setmetatable(enabled_headers, _nop_tostring_mt)
  end
```

5. **ssl证书等文件路径配置**
```
  -- load absolute paths
  conf.prefix = pl_path.abspath(conf.prefix)
  conf.go_pluginserver_exe = pl_path.abspath(conf.go_pluginserver_exe)
  if conf.go_plugins_dir ~= "off" then
    conf.go_plugins_dir = pl_path.abspath(conf.go_plugins_dir)
  end

  if conf.ssl_cert and conf.ssl_cert_key then
    conf.ssl_cert = pl_path.abspath(conf.ssl_cert)
    conf.ssl_cert_key = pl_path.abspath(conf.ssl_cert_key)
  end

  if conf.client_ssl_cert and conf.client_ssl_cert_key then
    conf.client_ssl_cert = pl_path.abspath(conf.client_ssl_cert)
    conf.client_ssl_cert_key = pl_path.abspath(conf.client_ssl_cert_key)
  end

  if conf.admin_ssl_cert and conf.admin_ssl_cert_key then
    conf.admin_ssl_cert = pl_path.abspath(conf.admin_ssl_cert)
    conf.admin_ssl_cert_key = pl_path.abspath(conf.admin_ssl_cert_key)
  end

  if conf.lua_ssl_trusted_certificate then
    conf.lua_ssl_trusted_certificate =
      pl_path.abspath(conf.lua_ssl_trusted_certificate)
  end

  if conf.cluster_cert and conf.cluster_cert_key then
    conf.cluster_cert = pl_path.abspath(conf.cluster_cert)
    conf.cluster_cert_key = pl_path.abspath(conf.cluster_cert_key)
  end
```
6. **kong自身文件目录配置**
```lua
  -- attach prefix files paths
  --PREFIX_PATHS中指定了如error.log等文件的目录，在此处理
  for property, t_path in pairs(PREFIX_PATHS) do
    conf[property] = pl_path.join(conf.prefix, unpack(t_path))
  end
  log.verbose("prefix in use: %s", conf.prefix)
  -- initialize the dns client, so the globally patched tcp.connect method
  -- will work from here onwards.
  assert(require("kong.tools.dns")(conf))

  return setmetatable(conf, nil) -- remove Map mt
end
```
以上逻辑结束后，返回conf对象，其元表配置为nil。继续返回上层`kong.init()`。

### pdk init

```lua
  kong_global.init_pdk(kong, config, nil) -- nil: latest PDK
```

### db初始化
```lua
  -- new返回了一个描述整个db中表映射结构的db表
  local db = assert(DB.new(config))
```
看一下其内部实现：
```lua
function DB.new(kong_config, strategy)
  ...param check
   
  strategy = strategy or kong_config.database

  local schemas = {}

  do
    -- load schemas
    -- core entities are for now the only source of schemas.
    -- TODO: support schemas from plugins entities as well.
    -- CORE_ENTITIES中记录了kong的核心资源对象，比如service route target upstream等
	-- 假设entuty_name为route
    for _, entity_name in ipairs(constants.CORE_ENTITIES) do
	  -- 加载kong.db.schema.entities.routes的定义，其返回了一个定义了name 、表字段、主键等值的表
      local entity_schema = require("kong.db.schema.entities." .. entity_name)
      -- entity验证
      -- validate core entities schema via metaschema
      local ok, err_t = MetaSchema:validate(entity_schema)
      ... 
      -- 返回描述entity的表	  
      local entity, err = Entity.new(entity_schema)
      ...
	  -- schemas[routes] = entity  像schemas中添加各核心变量的描述
      schemas[entity_name] = entity

      -- load core entities subschemas
      local subschemas
	  -- 尝试load kong.db.schema.entities.routes_subschemas，如果存在，将描述写入entity
      ok, subschemas = utils.load_module_if_exists("kong.db.schema.entities." .. entity_name .. "_subschemas")
      if ok then
        for name, subschema in pairs(subschemas) do
          local ok, err = entity:new_subschema(name, subschema)
         ...
        end
      end
    end
  end

  -- load strategy
  -- kong_config即配置，strategy为kong_config.database即db相关配置
  -- 根据strategy中的配置，判断进行pg还是cassandra数据库的初始化，包括封装配置和sql语句
  -- connector封装配置， strategies描述各表的sql语句
  local connector, strategies, err = Strategies.new(kong_config, strategy,
                                                    schemas, errors)
  ...
  local daos = {}
  local self   = {
    daos       = daos,       -- each of those has the connector singleton
    strategies = strategies,
    connector  = connector,
    strategy   = strategy,
    errors     = errors,
    infos      = connector:infos(),
    kong_config = kong_config,
  }
  do
    -- load DAOs
    -- 为每一个kong字段加载dao层定义
    for _, schema in pairs(schemas) do
      local strategy = strategies[schema.name]
      if not strategy then
        return nil, fmt("no strategy found for schema '%s'", schema.name)
      end
      daos[schema.name] = DAO.new(self, schema, strategy, errors)
    end
  end
  -- self继承了DB
  return setmetatable(self, DB)
end

```
返回的self继承了DB对象，DB定义了database操作的一系列方法：
```lua

-- DB的__index定义，从DB对象中取值，其中rawget为不访问元表
local DB = {}
DB.__index = function(self, k)
  return DB[k] or rawget(self, "daos")[k]
end

function DB:init_connector()...end

function DB:init_worker()...end

function DB:connect()...end

function DB:setkeepalive()...end

function DB:close()...end

function DB:reset()...end

function DB:truncate(table_name)...end

function DB:set_events_handler(events)...end
```
回到kong/init.lua后，返回一个db对象，之后进行db的初始化，表的创建等工作
```lua
  assert(db:init_connector())
  -- 执行表的初始化，包括routes表以及plugins表
  schema_state = assert(db:schema_state())
  migrations_utils.check_state(schema_state)
  ...
  -- 执行获取db连接操作
  assert(db:connect())
  -- 检查db描述的plugins和config所描述是否有出入
  assert(db.plugins:check_db_against_config(config.loaded_plugins))
```
### dns与证书设置
```lua
  -- LEGACY
  -- 解析conf中的dns配置，调用openresty的resty.dns.client init方法初始化
  singletons.dns = dns(config)
  singletons.configuration = config
  singletons.db = db
  -- /LEGACY
  kong.db = db
  kong.dns = singletons.dns
  if subsystem == "stream" or config.proxy_ssl_enabled then
    certificate.init()
  end
  if subsystem == "http" then
    clustering.init(config)
  end
```
### 加载插件
```lua
  -- Load plugins as late as possible so that everything is set up
  -- 这里最终通过require加载kong.plugins.{plugin}.handler
  assert(db.plugins:load_plugin_schemas(config.loaded_plugins))

  if kong.configuration.database == "off" then

    local err
    declarative_entities, err, declarative_meta = parse_declarative_config(kong.configuration)
    if not declarative_entities then
      error(err)
    end

  else
    local default_ws = db.workspaces:select_by_name("default")
    kong.default_workspace = default_ws and default_ws.id

    local ok, err = runloop.build_plugins_iterator("init")
    if not ok then
      error("error building initial plugins: " .. tostring(err))
    end

    assert(runloop.build_router("init"))
  end

  db:close()
end
```

## kong init_worker()

kong的init阶段完成静态配置/db等的初始化工作，init

```lua
function Kong.init_worker()
  kong_global.set_phase(kong, PHASES.init_worker)
  -- special math.randomseed from kong.globalpatches not taking any argument.
  -- Must only be called in the init or init_worker phases, to avoid
  -- duplicated seeds.
  math.randomseed()


  -- init DB
  -- 根据db的选型，调用具体db实例中connector的init_worker(),pg默认返回true
  local ok, err = kong.db:init_worker()
  ...
```
### 事件初始化

kong的事件机制[参考](https://ms2008.github.io/2018/06/11/kong-events-cache/), 其中：

- worker 之间的事件，由 [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events) 来处理

- cluster 节点之间的事件，由 lua实现的cluster_events.lua 来处理


1. **worker events**

它提供了一种向Nginx服务器中的其他worker进程发送事件的方法。通信是通过一个共享的存储区(shm)进行的，事件数据将存储在该shm中。可参考[示例](https://xwl.io/post/openresty-worker-events/)
```lua
  -- 引用"resty.worker.events"，配置事件
  local worker_events, err = kong_global.init_worker_events()
  ...
  kong.worker_events = worker_events
```

work-events的使用示例，首先是conf文件：
```
#user  nobody;
worker_processes  4;
error_log  /root/openresty/logs/error.log  info;
events {
    worker_connections  1024;
}

http {
    # 定义要加载的work-events位置
    lua_package_path "/usr/local/openresty/lualib/resty/?.lua;;";

    # the size depends on the number of event to handle:
    lua_shared_dict process_events 1m;
    # 根据文档说明，handler的定义和注册 以及configuer在init_worker阶段
    init_worker_by_lua_block {
        local ev = require "resty.worker.events"
        # 定义事件配置
        local ok, err = ev.configure {
            shm = "process_events", -- defined by "lua_shared_dict"
            timeout = 2,            -- life time of unique event data in shm
            interval = 1,           -- poll interval (seconds)

            wait_interval = 0.010,  -- wait before retry fetching event data
            wait_max = 0.5,         -- max wait time before discarding event
            shm_retries = 999,      -- retries for shm fragmentation (no memory)
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to start event system: ", err)
            return
        end
		# handler定义与注册
		local handler = function(data, event, source, pid)
            print("received event; source=",source,
                  ", event=",event,
                  ", data=", tostring(data),
                  ", from process ",pid)
        end

        ev.register(handler)
        
    }

    server {
        listen 30001;

        # example for post:
        location = /events {
             
            default_type text/plain;
            content_by_lua_block {
                -- manually call `poll` to stay up to date, can be used instead,
                -- or together with the timer interval. Polling is efficient,
                -- so if staying up-to-date is important, this is preferred.
				# 当访问events路径时，发送事件给各个worker
                local ok, err = require("resty.worker.events").post("jzd","test","123")
                if ok then
                        ngx.say("hello")
                end
                ngx.say("= =")
                -- do regular stuff here

            }
        }
    }
}
```
当访问conf监听的端口时，根据conf定义查看error.log信息，可以看到：
```
# 可以看到事件通知来自31969进程
2021/10/25 09:55:27 [notice] 31971#0: *72 [lua] init_worker_by_lua:19: received event; source=jzd, event=test, data=123, from process 31969, context: ngx.timer
2021/10/25 09:55:27 [notice] 31972#0: *74 [lua] init_worker_by_lua:19: received event; source=jzd, event=test, data=123, from process 31969, context: ngx.timer
2021/10/25 09:55:27 [notice] 31969#0: *76 [lua] init_worker_by_lua:19: received event; source=jzd, event=test, data=123, from process 31969, context: ngx.timer
2021/10/25 09:55:27 [notice] 31970#0: *78 [lua] init_worker_by_lua:19: received event; source=jzd, event=test, data=123, from process 31969, context: ngx.timer
```
查看openresty启动的所有worker进程，看到31969为第一个worker进程：
```
[root@iZ2zebl327dijrrsaeq81zZ ~]# ps -ef|grep nginx
root     25632     1  0 Oct23 ?        00:00:00 nginx: master process openresty -c /root/openresty/conf/work-events.conf
root     31969 25632  0 09:53 ?        00:00:00 nginx: worker process
root     31970 25632  0 09:53 ?        00:00:00 nginx: worker process
root     31971 25632  0 09:53 ?        00:00:00 nginx: worker process
root     31972 25632  0 09:53 ?        00:00:00 nginx: worker process
```


2. **cluster_events**


```lua
  local cluster_events, err = kong_global.init_cluster_events(kong.configuration, kong.db)
  ...
  kong.cluster_events = cluster_events
```
初始化的实现位于`kong/cluster_events目录中的init.lua`，其中定义了事件的`broadcast、subscribe`等方法：
```lua
function _M.new(opts)
  ...
  -- opts validations
  ...
  -- strategy selection

  local strategy
  local poll_interval = max(opts.poll_interval or 5, 0)
  local poll_offset   = max(opts.poll_offset   or 0, 0)
  local poll_delay    = max(opts.poll_delay    or 0, 0)
  -- 加载具体db的strategy
  do
    local db_strategy
    if opts.db.strategy == "cassandra" then
      db_strategy = require "kong.cluster_events.strategies.cassandra"

    elseif opts.db.strategy == "postgres" then
      db_strategy = require "kong.cluster_events.strategies.postgres"

    elseif opts.db.strategy == "off" then
      db_strategy = require "kong.cluster_events.strategies.off"

    else
      return error("no cluster_events strategy for " ..
                   opts.db.strategy)
    end

    local event_ttl_in_db = max(poll_offset * 10, MIN_EVENT_TTL_IN_DB)

    strategy = db_strategy.new(opts.db, PAGE_SIZE, event_ttl_in_db)
  end

  -- instantiation
  local self      = {
    -- 使用全局变量ngx.shared
    shm           = ngx.shared.kong,
    events_shm    = ngx.shared.kong_cluster_events,
    strategy      = strategy,
    poll_interval = poll_interval,
    poll_offset   = poll_offset,
    poll_delay    = poll_delay,
    event_ttl_shm = poll_interval * 2 + poll_offset,
    node_id       = nil,
    polling       = false,
    channels      = {},
    callbacks     = {},
    use_polling   = strategy:should_use_polling(),
  }

  -- 向封装的共享全局变量设置时间等属性
  -- set current time (at)

  local now = strategy:server_time() or ngx_now()
  local ok, err = self.shm:safe_set(CURRENT_AT_KEY, now)
  ...
  -- set node id (uuid)
  self.node_id, err = knode.get_id()
  ...
  if ngx_debug and opts.node_id then
    self.node_id = opts.node_id
  end
  _init = true
  -- 将返回的self继承自_M,后者实现了broadcast/subscribe等方法
  -- local _M = {}， local mt = { __index = _M }
  return setmetatable(self, mt)
end
```
### 缓存初始化

分别初始化kong的cache和core cache，其中：
```lua
  local cache, err = kong_global.init_cache(kong.configuration, cluster_events, worker_events)
  ...
  kong.cache = cache

  local core_cache, err = kong_global.init_core_cache(kong.configuration, cluster_events, worker_events)
  ...
  kong.core_cache = core_cache
```
1. **cache**

调用cache.lua返回一个对象：
```lua
function _GLOBAL.init_cache(kong_config, cluster_events, worker_events)
  local db_cache_ttl = kong_config.db_cache_ttl
  -- cache page用于设置缓存个数
  local cache_pages = 1
  if kong_config.database == "off" then
    db_cache_ttl = 0
    cache_pages = 2
  end
  -- 调用cache.lua中的new，
  return kong_cache.new {
    shm_name          = "kong_db_cache",
    cluster_events    = cluster_events,
    worker_events     = worker_events,
    ttl               = db_cache_ttl,
    neg_ttl           = db_cache_ttl,
    resurrect_ttl     = kong_config.resurrect_ttl,
    cache_pages       = cache_pages,
    resty_lock_opts   = {
      exptime = 10,
      timeout = 5,
    },
  }
end
```
继续看cache中的实现,cache的实现使用了[resty cache](https://github.com/thibaultcha/lua-resty-mlcache)：
```lua
function _M.new(opts)
  -- 参数检查，省略
  ...
  local mlcaches = {}
  local shm_names = {}
  -- 默认为1，即channel_name为mlcache, shm_name=kong_db_cache, shm_miss_name=kong_db_cache_miss
  for i = 1, opts.cache_pages or 1 do
    local channel_name  = (i == 1) and "mlcache"                 or "mlcache_2"
    local shm_name      = (i == 1) and opts.shm_name             or opts.shm_name .. "_2"
    local shm_miss_name = (i == 1) and opts.shm_name .. "_miss"  or opts.shm_name .. "_miss_2"
    -- 在ngx.shared中检查共享变量kong_db_cache和kong_db_cache_miss，疑问，这几个key是何时set入shared的？
	...
    if ngx.shared[shm_name] then
	  -- 调用多级缓存库resty.mlcache
      -- 参数说明参考 https://github.com/thibaultcha/lua-resty-mlcache#new	  
      local mlcache, err = resty_mlcache.new(shm_name, shm_name, {
        shm_miss         = shm_miss_name,
        shm_locks        = "kong_locks",
        shm_set_retries  = 3,
        lru_size         = LRU_SIZE,
        ttl              = max(opts.ttl     or 3600, 0),
        neg_ttl          = max(opts.neg_ttl or 300,  0),
        resurrect_ttl    = opts.resurrect_ttl or 30,
        resty_lock_opts  = opts.resty_lock_opts,
        -- mlcache的L1缓存在各个worker中独立，ipc提供了用于在各个worker间进行缓存同步的机制
		ipc = {
		  -- 注册事件handler与广播事件
          register_listeners = function(events)
            for _, event_t in pairs(events) do
			  -- 向worker_events注册事件的handler
              opts.worker_events.register(function(data)
                event_t.handler(data)
              end, channel_name, event_t.channel)
            end
          end,
		  -- 注册广播方法，channel_name为事件源，channel为事件名，data为事件内容
          broadcast = function(channel, data)
            local ok, err = opts.worker_events.post(channel_name, channel, data)
            ...
          end
        }
      })
      ...
      mlcaches[i] = mlcache
      shm_names[i] = shm_name
    end
  end

  local curr_mlcache = 1

  if opts.cache_pages == 2 then
    curr_mlcache = ngx.shared.kong:get("kong:cache:" .. opts.shm_name .. ":curr_mlcache") or 1
  end

  local self          = {
    cluster_events    = opts.cluster_events,
    mlcache           = mlcaches[curr_mlcache],
    mlcaches          = mlcaches,
    shm_names         = shm_names,
    curr_mlcache      = curr_mlcache,
  }
  -- 订阅缓存失效事件，subscribe的实现为 向cluster_events的callbackes表中注册名为invalidations的function
  local ok, err = self.cluster_events:subscribe("invalidations", function(key)
    log(DEBUG, "received invalidate event from cluster for key: '", key, "'")
	-- 从mlcache中删除指定key
	self:invalidate_local(key)
  end)
  ...
  _init[opts.shm_name] = true

  return setmetatable(self, mt)
end
...
```

2. **core cache**

core cache的实现与cache相同，只是名称为`kong_core_db_cache`,不再赘述。
```lua
function _GLOBAL.init_core_cache(kong_config, cluster_events, worker_events)
  local db_cache_ttl = kong_config.db_cache_ttl
  local cache_pages = 1
  ...
  -- 与 cache相同
  return kong_cache.new {
    shm_name          = "kong_core_db_cache",
    cluster_events    = cluster_events,
    worker_events     = worker_events,
    ttl               = db_cache_ttl,
    neg_ttl           = db_cache_ttl,
    resurrect_ttl     = kong_config.resurrect_ttl,
    cache_pages       = cache_pages,
    resty_lock_opts   = {
      exptime = 10,
      timeout = 5,
    },
  }
end

```

### 路由处理

```lua
  -- 从core_cache中检查key为router:version 和 plugins_iterator:version的值
  ok, err = runloop.set_init_versions_in_cache()
  ...
  -- 置为全局单例 singletons
  -- LEGACY
  singletons.cache          = cache
  singletons.core_cache     = core_cache
  singletons.worker_events  = worker_events
  singletons.cluster_events = cluster_events
  -- /LEGACY

  -- 遍历每个资源对象的dao，dao.events = worker_events
  kong.db:set_events_handler(worker_events)
  
  -- 重要，将db的相关配置load到kong.core_cache
  ok, err = load_declarative_config(kong.configuration, declarative_entities)
```

`load_declarative_config`的函数实现如下:

```lua
local function load_declarative_config(kong_config, entities)
  ...
  if not kong_config.declarative_config then
    -- no configuration yet, just build empty plugins iterator
	-- load plugin的iterator，这个迭代器包含了plugin的handler、与routes/services/consumers的关系等描述
    local new_version, err = kong.core_cache:get("plugins_iterator:version", TTL_ZERO, utils.uuid)
    ...
    local ok, err = runloop.build_plugins_iterator(new_version)
    ...
    return true
  end

  local opts = {
    name = "declarative_config",
  }
  -- concurrency.with_worker_mutex(opts,fn) 为根据opts配置获取resty.lock锁，执行fn后释放锁
  return concurrency.with_worker_mutex(opts, function()
    
	local value = ngx.shared.kong:get("declarative_config:loaded")
    ...

    local ok, err = declarative.load_into_cache(entities)
    if not ok then
      return nil, err
    end
    
    ok, err = runloop.build_plugins_iterator("init")
    ...
    -- 重要，根据load的资源配置，创建router，实现位于kong/router.lua的new中
    assert(runloop.build_router("init"))

    ok, err = ngx.shared.kong:safe_set("declarative_config:loaded", true)
    ...

    return true
  end)
end
```
**runloop.build_router("init")**中根据db的表述执行route资源的创建，其中同样定义的**find_route方法**，之后单独分析。

### init最终阶段
init的最终阶段包括
- 缓存加载
- 注册缓存事件、route刷新定义
- 插件

```lua
  -- 将dao层资源加载进kong.core_cache
  ok, err = execute_cache_warmup(kong.configuration)
  if not ok then
    ngx_log(ngx_ERR, "failed to warm up the DB cache: " .. err)
  end
  -- 这里的before函数比较重要
  runloop.init_worker.before()
```
查看`runloop.init_worker.before()`的实现：
```lua
  init_worker = {
    before = function()
      if kong.configuration.anonymous_reports then
        reports.configure_ping(kong.configuration)
        reports.add_ping_value("database_version", kong.db.infos.db_ver)
        reports.toggle(true)
        reports.init_worker()
      end
	  -- 清理缓存ngx.shared.kong
      update_lua_mem(true)
	  -- 重要，注册kong.worker_events与cluster_events的事件，此处之后单独分析
      register_events()

	  -- 负载均衡的Init	
      -- initialize balancers for active healthchecks
      timer_at(0, function()
        balancer.init()
      end)

      local router_update_frequency = kong.configuration.router_update_frequency or 1
      -- 根据配置的刷新频率，更新路由以及plugin
      timer_every(router_update_frequency, function(premature)
        ...
        local ok, err = rebuild_router(ROUTER_ASYNC_OPTS)
        ...
      end)

      timer_every(router_update_frequency, function(premature)
        ...
        local ok, err = rebuild_plugins_iterator(PLUGINS_ITERATOR_ASYNC_OPTS)
        if not ok then
          log(ERR, "could not rebuild plugins iterator via timer: ", err)
        end
      end)
	...

    end
  },

```
## plugin 迭代器
```
  --
  local init_worker_plugins_iterator = runloop.build_plugins_iterator_for_init_worker_phase()
  execute_plugins_iterator(init_worker_plugins_iterator, "init_worker")

  -- run plugins init_worker context
  local retries = 5
  ok, err = runloop.update_plugins_iterator(retries)
  if not ok then
    ngx_log(ngx_ERR, "failed to build the plugins iterator: ", err)
  end

  if go.is_on() then
    go.manage_pluginserver()
  end

  if subsystem == "http" then
    clustering.init_worker(kong.configuration)
  end
end
```

# 参考
[1](https://cloud.tencent.com/developer/article/1489439)
[2 kong事件与缓存] (https://ms2008.github.io/2018/06/11/kong-events-cache/)