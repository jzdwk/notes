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

`Kong.init()`位于`/usr/local/share/lua/5.1/kong/init.lua`中：

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
  -- we are 200 OK
  return setmetatable(self, DB)
end
```
最终，返回一个db对象，之后进行db的初始化，表的创建等工作
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

# 参考
[1](https://cloud.tencent.com/developer/article/1489439)