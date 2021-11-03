# kong rewrite

查看kong的配置文件nginx-kong.conf，其rewrite阶段定义如下：
```
server {
	...
	rewrite_by_lua_block {
        Kong.rewrite()
    }
	...
}
```

## rewrite

其实现位于`/kong/init.lua`的rewirte()函数：
```lua
function Kong.rewrite()
  -- grpc 处理，暂时忽略
  ...

  local ctx = ngx.ctx
  ...
  kong_global.set_phase(kong, PHASES.rewrite)
  -- 调用FFI库的ngx_http_lua_ffi_get_ctx_ref，将返回值写入ngx.var.ctx_ref。暂时没搞懂ngx_http_lua_ffi_get_ctx_ref的作用
  kong_resty_ctx.stash_ref()
	
  local is_https = var.https == "on"
  if not is_https then
    log_init_worker_errors(ctx)
  end

  -- 调用rewrite阶段的before
  runloop.rewrite.before(ctx)
```
### runloop rewrite

runloop中定义了kong在init_worker/preread/rewrite/access等阶段中，不同时期具体的执行函数。**这几个阶段即Kong在插件开发时指定的阶段**，详见kong-plugin-dev中说明.
实现位于`/kong/runloop/handler.lua`中：
```lua
  rewrite = {
    before = function(ctx)
      -- special handling for proxy-authorization and te headers in case
      -- the plugin(s) want to specify them (store the original)
      ctx.http_proxy_authorization = var.http_proxy_authorization
      ctx.http_te                  = var.http_te
    end,
  },
```
### plugin rewrite

执行加载的plugin的rewrite逻辑，这里注意，**根据kong的插件开发说明，如果plugin重写了rewrite()阶段，则此插件只能被配置为全局插件**，相应的，**kong会执行所有的重写了该阶段的插件**:

```lua
  -- On HTTPS requests, the plugins iterator is already updated in the ssl_certificate phase
  local plugins_iterator
  if is_https then
    plugins_iterator = runloop.get_plugins_iterator()
  else
    plugins_iterator = runloop.get_updated_plugins_iterator()
  end
  -- 执行所有加载的插件的rewrite阶段逻辑	
  execute_plugins_iterator(plugins_iterator, "rewrite", ctx)

  ctx.KONG_REWRITE_ENDED_AT = get_now_ms()
  ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT - ctx.KONG_REWRITE_START
end
```
具体为遍历迭代器，获取插件的conf，执行：
```lua
local function execute_plugins_iterator(plugins_iterator, phase, ctx)
  for plugin, configuration in plugins_iterator:iterate(phase, ctx) do
    if ctx then
      ...
      kong_global.set_named_ctx(kong, "plugin", plugin.handler)
    end

    kong_global.set_namespaced_log(kong, plugin.name)
	-- configuration 为插件的conf配置，详见kong-plugin-dev中说明
    plugin.handler[phase](plugin.handler, configuration)
    kong_global.reset_log(kong)
  end
end
```