# kong access

**access阶段是openresty处理请求访问的核心阶段**，主要用于集中处理IP准入、接口权限、访问控制等情况。

查看kong的配置文件nginx-kong.conf，其access阶段定义如下：
```
server {
	...
	rewrite_by_lua_block {
        Kong.rewrite()
    }
	...
}
```

相应的，kong的access阶段中用于**处理client端请求，并在其将请求代理到上游(upstream)服务之前执行注册的逻辑。大多数的plugin均在该阶段实现核心业务逻辑。**

## access

其实现位于`/kong/init.lua`的access()函数，整理的实现上来说，access的代码结构与rewriete阶段类似：
```lua
function Kong.access()
  local ctx = ngx.ctx
  ...
  kong_global.set_phase(kong, PHASES.access)
  -- 与rewrite一样，执行before
  runloop.access.before(ctx)

  ctx.delay_response = true
  -- 
  local plugins_iterator = runloop.get_plugins_iterator()
  for plugin, plugin_conf in plugins_iterator:iterate("access", ctx) do
    if plugin.handler._go then
      ctx.ran_go_plugin = true
    end

    if not ctx.delayed_response then
      kong_global.set_named_ctx(kong, "plugin", plugin.handler)
      kong_global.set_namespaced_log(kong, plugin.name)

      local err = coroutine.wrap(plugin.handler.access)(plugin.handler, plugin_conf)
      if err then
        kong.log.err(err)
        ctx.delayed_response = {
          status_code = 500,
          content     = { message  = "An unexpected error occurred" },
        }
      end

      kong_global.reset_log(kong)
    end
  end

  if ctx.delayed_response then
    ctx.KONG_ACCESS_ENDED_AT = get_now_ms()
    ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START
    ctx.KONG_RESPONSE_LATENCY = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_PROCESSING_START

    return flush_delayed_response(ctx)
  end

  ctx.delay_response = false

  if not ctx.service then
    ctx.KONG_ACCESS_ENDED_AT = get_now_ms()
    ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START
    ctx.KONG_RESPONSE_LATENCY = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_PROCESSING_START

    return kong.response.exit(503, { message = "no Service found with those values"})
  end
  
  runloop.access.after(ctx)

  ctx.KONG_ACCESS_ENDED_AT = get_now_ms()
  ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START

  -- we intent to proxy, though balancer may fail on that
  ctx.KONG_PROXIED = true

  if kong.ctx.core.buffered_proxying then
    return buffered_proxy(ctx)
  end
end
```
### runloop access before

runloop中定义了kong在init_worker/preread/rewrite/access等阶段中，不同时期具体的执行函数。**这几个阶段即Kong在插件开发时指定的阶段**，详见kong-plugin-dev中说明.

access的实现位于`/kong/runloop/handler.lua`，主要调用了before与after函数，其中当请求匹配到了kong的route后才会调用after：
```lua
  access = {
    before = function(ctx)...end,
    -- Only executed if the `router` module found a route and allows nginx to proxy it.
    after = function(ctx)...end
  },
```

before函数中最重要的工作为：**根据请求匹配到init阶段加载的router，并将对应的kong资源赋值给ngx.ctx**
```lua
    before = function(ctx)
      -- if there is a gRPC service in the context, don't re-execute the pre-access
      -- phase handler - it has been executed before the internal redirect
      ...
      
      -- routing request
      local router = get_updated_router()
	  -- 重点，根据加载的router，执行匹配逻辑，成功后返回match_t记录
      local match_t = router.exec()
      if not match_t then
        return kong.response.exit(404, { message = "no Route matched with those values" })
      end
	  -- 从ngx.var获取请求信息，并
      local http_version   = ngx.req.http_version()
      local scheme         = var.scheme
      local host           = var.host
      local port           = tonumber(var.server_port, 10)
      local content_type   = var.content_type

      local route          = match_t.route
      local service        = match_t.service
      local upstream_url_t = match_t.upstream_url_t

      local realip_remote_addr = var.realip_remote_addr
      local forwarded_proto
      local forwarded_host
      local forwarded_port
      -- 处理X-Forwarded-* HTTP头，处理的原因为：
	  -- 当nginx启用realip module，该模块会将$remote_addr（即http头的remoteAddress）覆盖为实际值
	  -- 比如client访问server时中间存在一个代理的proxy，则$remote_addr为代理的地址，而非真正访问的cient地址。
	  -- 而client的实际值将会在X-real-ip头中。
	  
	  -- 因此当使用了http头X-Forwarded-For后，realip_remote_addr为realip moudle模块覆盖前的remode_addr的IP值。
	  
	  -- X-Forwarded-* / X-real-ip /remoteAddress的作用请参考 https://imququ.com/post/x-forwarded-for-header-in-http.html
      -- X-Forwarded-* Headers Parsing
      -- We could use $proxy_add_x_forwarded_for, but it does not work properly
      -- with the realip module. The realip module overrides $remote_addr and it
      -- is okay for us to use it in case no X-Forwarded-For header was present.
      -- But in case it was given, we will append the $realip_remote_addr that
      -- contains the IP that was originally in $remote_addr before realip
      -- module overrode that (aka the client that connected us).
      -- 如果client ip可信，http在原始头上追加，否则使用请求中的实际信息
      local trusted_ip = kong.ip.is_trusted(realip_remote_addr)
      if trusted_ip then
        forwarded_proto = var.http_x_forwarded_proto or scheme
        forwarded_host  = var.http_x_forwarded_host  or host
        forwarded_port  = var.http_x_forwarded_port  or port
      
      else
        forwarded_proto = scheme
        forwarded_host  = host
        forwarded_port  = port
      end
	  -- 接下来处理访问时的schema格式问题：
      -- 1.使用http访问https服务的处理，返回426或者直接重定向
      local protocols = route.protocols
      if (protocols and protocols.https and not protocols.http and
          forwarded_proto ~= "https")
      then
        local redirect_status_code = route.https_redirect_status_code or 426
        if redirect_status_code == 426 then
          return kong.response.exit(426, { message = "Please use HTTPS protocol" }, {
            ["Connection"] = "Upgrade",
            ["Upgrade"]    = "TLS/1.2, HTTP/1.1",
          })
        end
        if redirect_status_code == 301 or
          redirect_status_code == 302 or
          redirect_status_code == 307 or
          redirect_status_code == 308 then
          header["Location"] = "https://" .. forwarded_host .. var.request_uri
          return kong.response.exit(redirect_status_code)
        end
      end

      -- 2.访问grpc服务的错误处理
      -- mismatch: non-http/2 request matched grpc route
      if (protocols and (protocols.grpc or protocols.grpcs) and http_version ~= 2 and
        (content_type and sub(content_type, 1, #"application/grpc") == "application/grpc"))
      then
        return kong.response.exit(426, { message = "Please use HTTP2 protocol" }, {
          ["connection"] = "Upgrade",
          ["upgrade"]    = "HTTP/2",
        })
      end
      -- mismatch: non-grpc request matched grpc route
      if (protocols and (protocols.grpc or protocols.grpcs) and
        (not content_type or sub(content_type, 1, #"application/grpc") ~= "application/grpc"))
      then
        return kong.response.exit(415, { message = "Non-gRPC request matched gRPC route" })
      end
      -- mismatch: grpc request matched grpcs route
      if (protocols and protocols.grpcs and not protocols.grpc and
        forwarded_proto ~= "https")
      then
        return kong.response.exit(200, nil, {
          ["grpc-status"] = 1,
          ["grpc-message"] = "gRPC request matched gRPCs route",
        })
      end


      -- 重要，向ngx.ctx写入访问后端实际upstream前的data
      balancer_prepare(ctx, match_t.upstream_scheme,
                       upstream_url_t.type,
                       upstream_url_t.host,
                       upstream_url_t.port,
                       service, route)

      ctx.router_matches = match_t.matches

      -- `uri` is the URI with which to call upstream, as returned by the
      --       router, which might have truncated it (`strip_uri`).
      -- `host` is the original header to be preserved if set.
      var.upstream_scheme = match_t.upstream_scheme -- COMPAT: pdk
      var.upstream_uri    = match_t.upstream_uri
      var.upstream_host   = match_t.upstream_host

      -- Keep-Alive and WebSocket Protocol Upgrade Headers
      if var.http_upgrade and lower(var.http_upgrade) == "websocket" then
        var.upstream_connection = "keep-alive, Upgrade"
        var.upstream_upgrade    = "websocket"

      else
        var.upstream_connection = "keep-alive"
      end

      -- X-Forwarded-* Headers 的赋值
      local http_x_forwarded_for = var.http_x_forwarded_for
	  -- X-Forwarded-*中追加real ip
      if http_x_forwarded_for then
        var.upstream_x_forwarded_for = http_x_forwarded_for .. ", " ..
                                       realip_remote_addr
	  else
	  -- 否则追加实际的remoteAddr值，有可能只是一个proxy，而非client，的ip
        var.upstream_x_forwarded_for = var.remote_addr
      end

      var.upstream_x_forwarded_proto = forwarded_proto
      var.upstream_x_forwarded_host  = forwarded_host
      var.upstream_x_forwarded_port  = forwarded_port

      -- At this point, the router and `balancer_setup_stage1` have been
      -- executed; detect requests that need to be redirected from `proxy_pass`
      -- to `grpc_pass`. After redirection, this function will return early
	  
      if service and var.kong_proxy_mode == "http" then
        if service.protocol == "grpc" then
          return ngx.exec("@grpc")
        end

        if service.protocol == "grpcs" then
          return ngx.exec("@grpcs")
        end
      end
    end,

```
下面，看一下router匹配的具体实现.

#### route match

kong的路由匹配在before代码中的`local match_t = router.exec()`,其实现位于`/kong/router.lua`
```lua
  --	以http服务为例
  -- 	req_method	=	ngx.req.get_method
  -- 	req_uri		=	ngx.var.request_uri
  --	req_host	=	ngx.var.http_host
  --	req_scheme	=	ngx.var.scheme
  --	src_ip/src_port/dst_ip/dst_port		=	nil
  --	sni			=	ngx.var.ssl_server_name
  --	req_headers	=	ngx.req.get_headers，注意host头赋值为nil
  local function find_route(req_method, req_uri, req_host, req_scheme,
                            src_ip, src_port,
                            dst_ip, dst_port,
                            sni, req_headers)
	-- ... err check  省略
    req_method = req_method or ""
    req_uri = req_uri or ""
    req_host = req_host or ""
    req_headers = req_headers or EMPTY_T

    -- 临时local变量ctx = {hits = {}, matches = {}}
    ctx.req_method     = req_method
    ctx.req_uri        = req_uri
    ctx.req_host       = req_host
    ctx.req_headers    = req_headers
    ctx.src_ip         = src_ip or ""
    ctx.src_port       = src_port or ""
    ctx.dst_ip         = dst_ip or ""
    ctx.dst_port       = dst_port or ""
    ctx.sni            = sni or ""
    local raw_req_host = req_host
    req_method = upper(req_method)

    -- 解析端口，如果host没有携带端口，使用默认
    local host_no_port, host_with_port = split_port(req_host,
                                                    req_scheme == "https"
                                                    and 443 or 80)
    ctx.host_with_port = host_with_port
    ctx.host_no_port   = host_no_port
    -- hit用于存储匹配目标
	local hits         = ctx.hits
    -- req_category用于记录匹配上的项，并用于最终的优先级计算，初始为0，
	-- 具体操作为与MATCH_RULES执行或操作，因各项互不干扰，故都匹配后，req_category为0x0000007F
	--[[
			local MATCH_RULES = {
				HOST            = 0x00000040,
				HEADER          = 0x00000020,
				URI             = 0x00000010,
				METHOD          = 0x00000008,
				SNI             = 0x00000004,
				SRC             = 0x00000002,
				DST             = 0x00000001,
			}
	]]--
	local req_category = 0x00
    clear_tab(hits)

    -- router, router, which of these routes is the fairest?
    --
    -- determine which category this request *might* be targeting

	-- plain_indexes中的内容来自init阶段，加载route时调用的local function index_route_t
	-- 具体实现位于/kong/router.lua的index_route_t函数
	-- index_route_t的实现为，遍历每个router的host/header/uri等属性，并缓存到对应的plain_indexes/prefix_uris/regex_uris等表中
	-- 其中，plain_indexes定义如下：
	--[[ 
		local plain_indexes = {
			hosts             = {},
			headers           = {},
			uris              = {},
			methods           = {},
			sources           = {},
			destinations      = {},
			snis              = {},
		}
	]]--
	-- prefix_uris/regex_uris/src_trust_funcs等表同理
	-- 1. 首先进行请求头处理，按plain_indexes.headers中缓存的header匹配请求，如果匹配上，置本地缓存ctx.hits.header_name，更新req_category
    for _, header_name in ipairs(plain_indexes.headers) do
      if req_headers[header_name] then
	    -- req_category = 0x00000020，
        req_category = bor(req_category, MATCH_RULES.HEADER)
        hits.header_name = header_name
        break
      end
    end

    -- cache lookup (except for headers-matched Routes)
    -- if trigger headers match rule, ignore routes cache
	-- 比如：cache_key = GET|/anything| | | | | | www.test.com
    local cache_key = req_method .. "|" .. req_uri .. "|" .. req_host ..
                      "|" .. ctx.src_ip .. "|" .. ctx.src_port ..
                      "|" .. ctx.dst_ip .. "|" .. ctx.dst_port ..
                      "|" .. ctx.sni
	-- 2. 从缓存中直接读取，缓存cache使用resty.lrucache的new直接创建，大小MATCH_LRUCACHE_SIZE = 5e3，即5000
    do
      local match_t = cache:get(cache_key)
      if match_t and hits.header_name == nil then
        return match_t
      end
    end

    -- 3. 匹配host，分为精确匹配和通配符匹配，更新req_category = 0x00000060
    if plain_indexes.hosts[host_with_port]
      or plain_indexes.hosts[host_no_port]
    then
      req_category = bor(req_category, MATCH_RULES.HOST)

    elseif ctx.req_host then
      for i = 1, #wildcard_hosts do
        local from, _, err = re_find(host_with_port, wildcard_hosts[i].regex,
                                     "ajo")
        if err then
          log(ERR, "could not match wildcard host: ", err)
          return
        end
        if from then
          hits.host    = wildcard_hosts[i].value
          req_category = bor(req_category, MATCH_RULES.HOST)
          break
        end
      end
    end

    -- 4. 匹配uri，顺序为：
	-- 正则匹配->精确匹配->前缀匹配，更新req_category = 0x00000070与hits
    for i = 1, #regex_uris do
	  -- 正则
      local from, _, err = re_find(req_uri, regex_uris[i].regex, "ajo")
      ...
      if from then
        hits.uri     = regex_uris[i].value
        req_category = bor(req_category, MATCH_RULES.URI)
        break
      end
    end
    -- 精确
    if not hits.uri then
      if plain_indexes.uris[req_uri] then
        hits.uri     = req_uri
        req_category = bor(req_category, MATCH_RULES.URI)
	  -- 前缀	
      else
        for i = 1, #prefix_uris do
          if find(req_uri, prefix_uris[i].value, nil, true) == 1 then
            hits.uri     = prefix_uris[i].value
            req_category = bor(req_category, MATCH_RULES.URI)
            break
          end
        end
      end
    end

    --5. 匹配http方法，更新req_category = 0x00000078
    if plain_indexes.methods[req_method] then
      req_category = bor(req_category, MATCH_RULES.METHOD)
    end

    --6. 匹配src，更新req_category = 0x0000007A
    if plain_indexes.sources[ctx.src_ip] then
      req_category = bor(req_category, MATCH_RULES.SRC)
    elseif plain_indexes.sources[ctx.src_port] then
      req_category = bor(req_category, MATCH_RULES.SRC)
    else
      for i = 1, #src_trust_funcs do
        if src_trust_funcs[i](ctx.src_ip) then
          req_category = bor(req_category, MATCH_RULES.SRC)
          break
        end
      end
    end

    --7. 匹配dst，更新req_category = 0x0000007B
    if plain_indexes.destinations[ctx.dst_ip] then
      req_category = bor(req_category, MATCH_RULES.DST)

    elseif plain_indexes.destinations[ctx.dst_port] then
      req_category = bor(req_category, MATCH_RULES.DST)
    else
      for i = 1, #dst_trust_funcs do
        if dst_trust_funcs[i](ctx.dst_ip) then
          req_category = bor(req_category, MATCH_RULES.DST)
          break
        end
      end
    end

	--8. 匹配dst，更新req_category = 0x0000007F
    if plain_indexes.snis[ctx.sni] then
      req_category = bor(req_category, MATCH_RULES.SNI)
    end

    --print("highest potential category: ", req_category)

    -- iterate from the highest matching to the lowest category to
    -- find our route
	
	-- req_category记录了所有匹配到的项
	-- categories_lookup[req_category]返回了一个需要首先处理的项的下标，比如host
    if req_category ~= 0x00 then
      local category_idx = categories_lookup[req_category] or 1
      local matched_route
      
      while category_idx <= categories_len do
        local bit_category = categories_weight_sorted[category_idx].category_bit
        -- 找到下标对应的项
		local category     = categories[bit_category]
        if category then
		  -- 这步没看懂，存疑？
          local reduced_candidates, category_candidates = reduce(category,
                                                                 bit_category,
                                                                 ctx)
          if reduced_candidates then
            -- check against a reduced set of routes that is a strong candidate
            -- for this request, instead of iterating over all the routes of
            -- this category
            for i = 1, #reduced_candidates do
			  -- 重要，路由匹配的核心实现逻辑
              if match_route(reduced_candidates[i], ctx) then
                matched_route = reduced_candidates[i]
                break
              end
            end
          end
          if not matched_route then
            -- no result from the reduced set, must check for results from the
            -- full list of routes from that category before checking a lower
            -- category
            for i = 1, #category_candidates do
			  -- 重要，路由匹配的核心实现逻辑
              if match_route(category_candidates[i], ctx) then
                matched_route = category_candidates[i]
                break
              end
            end
          end
```
这里的match_route实现如下：
```lua
  match_route = function(route_t, ctx)
    -- run cached matcher
    if type(matchers[route_t.match_rules]) == "function" then
      clear_tab(ctx.matches)
      return matchers[route_t.match_rules](route_t, ctx)
    end
	
    -- build and cache matcher

    local matchers_set = {}

    for _, bit_match_rule in pairs(MATCH_RULES) do
      if band(route_t.match_rules, bit_match_rule) ~= 0 then
        matchers_set[#matchers_set + 1] = matchers[bit_match_rule]
      end
    end

    matchers[route_t.match_rules] = function(route_t, ctx)
      -- clear matches context for this try on this route
      clear_tab(ctx.matches)

      for i = 1, #matchers_set do
        if not matchers_set[i](route_t, ctx) then
          return
        end
      end

      return true
    end

    return matchers[route_t.match_rules](route_t, ctx)
  end
  
  -- matchers中对各项的匹配逻辑function实现定义
  local matchers = {
    [MATCH_RULES.HOST] = function(route_t, ctx)...end,
    [MATCH_RULES.HEADER] = function(route_t, ctx)...end,
    [MATCH_RULES.URI] = function(route_t, ctx)...end,
    [MATCH_RULES.METHOD] = function(route_t, ctx)...end  
    [MATCH_RULES.DST] = function(route_t, ctx)...end    
    [MATCH_RULES.SNI] = function(route_t, ctx)...end 
  }

```
返回上层，当匹配到route后，将init阶段加载的route填充只matched_route:
```lua
          if matched_route then
            local upstream_host
            local upstream_uri
            local upstream_url_t = matched_route.upstream_url_t
            local matches        = ctx.matches

            if matched_route.route.id and routes_by_id[matched_route.route.id].route then
              matched_route.route = routes_by_id[matched_route.route.id].route
            end

            -- Path construction
			-- route的path处理，strip_path字段的v1/v0处理
            if matched_route.type == "http" then
              -- if we do not have a path-match, then the postfix is simply the
              -- incoming path, without the initial slash
              local request_postfix = matches.uri_postfix or sub(req_uri, 2, -1)
              local upstream_base = upstream_url_t.path or "/"
              if matched_route.route.path_handling == "v1" then
                if matched_route.strip_uri then
                  -- ...upstream_uri 的处理
                end
              else -- matched_route.route.path_handling == "v0"
                -- upstream_uri 处理
              end

              -- preserve_host header logic
              if matched_route.preserve_host then
                upstream_host = raw_req_host or var.http_host
              end
            end
			-- 最终的match封装
            local match_t     = {
              route           = matched_route.route,
              service         = matched_route.service,
              headers         = matched_route.headers,
              upstream_url_t  = upstream_url_t,
              upstream_scheme = upstream_url_t.scheme,
              upstream_uri    = upstream_uri,
              upstream_host   = upstream_host,
              matches         = {
                uri_captures  = matches.uri_captures,
                uri           = matches.uri,
                host          = matches.host,
                headers       = matches.headers,
                method        = matches.method,
                src_ip        = matches.src_ip,
                src_port      = matches.src_port,
                dst_ip        = matches.dst_ip,
                dst_port      = matches.dst_port,
                sni           = matches.sni,
              }
            }
			-- 添加入lru缓存，作为后续route匹配时的处理
            if band(matched_route.match_rules, MATCH_RULES.HEADER) == 0 then
              cache:set(cache_key, match_t)
            end
            return match_t
          end
        end
        -- check lower category
        category_idx = category_idx + 1
      end
    end

    -- no match :'(
  end

```
总之，kong在access阶段，根据请求的属性，从在init阶段已加载的route资源上去匹配。匹配成功返回封装的match表。

#### balancer_prepare
route匹配成功后，将请求信息写入ctx，作为balancer_data：
```lua
-- scheme		=	match_t.upstream_scheme
--	host_type	=	match_t.upstream_url_t.type,
--	host	=	match_t.upstream_url_t.host,
--	port	=	match_t.upstream_url_t.port,
--	service = 	match_t.service, 
--	route	=	match_t.route
function balancer_prepare(ctx, scheme, host_type, host, port,
                            service, route)
    local balancer_data = {
      scheme         = scheme,    -- scheme for balancer: http, https
      type           = host_type, -- type of 'host': ipv4, ipv6, name
      host           = host,      -- target host per `service` entity
      port           = port,      -- final target port
      try_count      = 0,         -- retry counter
      tries          = {},        -- stores info per try
      -- ip          = nil,       -- final target IP address
      -- balancer    = nil,       -- the balancer object, if any
      -- hostname    = nil,       -- hostname of the final target IP
      -- hash_cookie = nil,       -- if Upstream sets hash_on_cookie
      -- balancer_handle = nil,   -- balancer handle for the current connection
    }
    do
      local s = service or EMPTY_T
      balancer_data.retries         = s.retries         or 5
      balancer_data.connect_timeout = s.connect_timeout or 60000
      balancer_data.send_timeout    = s.write_timeout   or 60000
      balancer_data.read_timeout    = s.read_timeout    or 60000
    end
    ctx.service          = service
    ctx.route            = route
    ctx.balancer_data    = balancer_data
    ctx.balancer_address = balancer_data -- for plugin backward compatibility
    if service then
      local client_certificate = service.client_certificate
      if client_certificate then
        local cert, err = get_certificate(client_certificate)
        if not cert then
          log(ERR, "unable to fetch upstream client TLS certificate ",
                   client_certificate.id, ": ", err)
          return
        end

        local res
        res, err = kong.service.set_tls_cert_key(cert.cert, cert.key)
        if not res then
          log(ERR, "unable to apply upstream client TLS certificate ",
                   client_certificate.id, ": ", err)
        end
      end
    end
    if subsystem == "stream" and scheme == "tcp" then
      local res, err = kong.service.request.disable_tls()
      if not res then
        log(ERR, "unable to disable upstream TLS handshake: ", err)
      end
    end
  end
end
```

### plugin access

执行加载的plugin的access逻辑，**access阶段是大多数插件的核心实现阶段**。此阶段的执行与rewrite相同，因为只有匹配上route后才会进执行一下操作，故不再赘述

```lua
  local plugins_iterator = runloop.get_plugins_iterator()
  for plugin, plugin_conf in plugins_iterator:iterate("access", ctx) do
    ...
    if not ctx.delayed_response then
      kong_global.set_named_ctx(kong, "plugin", plugin.handler)
      kong_global.set_namespaced_log(kong, plugin.name)
      -- 启用协程执行plugin的access逻辑
      local err = coroutine.wrap(plugin.handler.access)(plugin.handler, plugin_conf)
      ... err handler
      kong_global.reset_log(kong)
    end
  end
```

### runloop access after

与before相同，access的实现位于`/kong/runloop/handler.lua`，其中当请求匹配到了kong的route后才会调用after：
```lua
  access = {
    before = function(ctx)...end,
    -- Only executed if the `router` module found a route and allows nginx to proxy it.
    after = function(ctx)...end
  },
```
具体实现：
```lua
after = function(ctx)
      do
        -- 空query args的简单处理
      end

      local balancer_data = ctx.balancer_data
      balancer_data.scheme = var.upstream_scheme -- COMPAT: pdk
      -- 重要，执行balance
      local ok, err, errcode = balancer_execute(ctx)
      if not ok then
        local body = utils.get_default_exit_body(errcode, err)
        return kong.response.exit(errcode, body)
      end
		
      var.upstream_scheme = balancer_data.scheme
	  -- ...http header处理 省略
      
    end
```

#### 执行lb 负载均衡

balancer是Kong实现负载均衡的核心，涉及的点包括了：
- 相关资源对象：service - upstream - target，当路由根据route匹配到service后，会根据service绑定的upstream以及upstream之后的target来负载到具体的endpoint
- 会话保持：kong的负载支持不同维护的会话保持，比如根据consumer/ip等
- 负载均衡算法选择

```lua
-- Resolves the target structure in-place (fields `ip`, `port`, and `hostname`).
--
-- If the hostname matches an 'upstream' pool, then it must be balanced in that
-- pool, in this case any port number provided will be ignored, as the pool
-- provides it.
--
-- @param target the data structure as defined in `core.access.before` where
-- it is created.
-- @return true on success, nil+error message+status code otherwise
-- target = ctx.balancer_data，即由上一步balancer_prepare返回的表

local function execute(target, ctx)
  -- 如果service后直接配置的ip，就没有lb什么事了，直接返回
  if target.type ~= "name" then
    -- it's an ip address (v4 or v6), so nothing we can do...
    target.ip = target.host
    target.port = target.port or 80 -- TODO: remove this fallback value
    target.hostname = target.host
    return true
  end
  
  -- when tries == 0,
  --   it runs before the `balancer` context (in the `access` context),
  -- when tries >= 2,
  --   then it performs a retry in the `balancer` context
  local dns_cache_only = target.try_count ~= 0
  local balancer, upstream, hash_value
  -- 缓存判断，如果已经执行过lb，则直接返回lb对象
  if dns_cache_only then
    -- retry, so balancer is already set if there was one
    balancer = target.balancer
  else
    -- first try, so try and find a matching balancer/upstream object
	-- 根据target的hostname，从init_worker阶段加载的upstream取出对象，并根据upstream.id，从balancer.lua的balancers表中得到对应的lb对象
	-- 其中balancers表来自于init_worker时注册的worker_events事件，重要，稍后分析
    balancer, upstream = get_balancer(target)
    if balancer == nil then -- `false` means no balancer, `nil` is error
      return nil, upstream, 500
    end
```
从balancer表中获取lb对象后，通过lb对象是否为空来判断是否需要执行lb：
```lua
    if balancer then
      -- store for retries
      target.balancer = balancer
      -- calculate hash-value
      -- only add it if it doesn't exist, in case a plugin inserted one
      hash_value = target.hash_value
      if not hash_value then
	    -- 根据upstream的hash_on计算hash，hash_on即设定的lb会话保持规则，比如consumer,ip,header,cookie
        hash_value = create_hash(upstream, ctx)
        target.hash_value = hash_value
      end
    end
  end
  local ip, port, hostname, handle
  -- 如果需要负载均衡lb，则根据lb选择endpoint
  if balancer then
    -- have to invoke the ring-balancer
    ip, port, hostname, handle = balancer:getPeer(dns_cache_only,
                                          target.balancer_handle,
                                          hash_value)
    ...
    hostname = hostname or ip
    target.hash_value = hash_value
    target.balancer_handle = handle
  -- 否则，直接根据dns得到endpoint，赋值给target
  else
    -- have to do a regular DNS lookup
    local try_list
    ip, port, try_list = toip(target.host, target.port, dns_cache_only)
    hostname = target.host
    ...
  end
  ...
  target.ip = ip
  target.port = port
  ...
  return true
end
```

##### balancer的创建
上一节中，`balancer, upstream = get_balancer(target)`根据target获取了balancer，此对象为负载均衡的实现。其创建过程与调用链如下：
```lua
--1. /kong/runloop/handler.lua init_worker阶段注册事件
init_worker = {
    before = function()
	  ...
      register_events()
	  ...
	end
}
-- 其中worker_events注册了balancer
  -- worker_events node handler
  worker_events.register(function(data)
    local operation = data.operation
    local upstream = data.entity

    -- => to balancer update
    balancer.on_upstream_event(operation, upstream)
  end, "balancer", "upstreams")

--2. on_upstream_event用于创建/更新balancer对象
-- Called on any changes to an upstream.
-- @param operation "create", "update" or "delete"
-- @param upstream_data table with `id` and `name` fields
local function on_upstream_event(operation, upstream_data)
  if operation == "reset" then
    init()
  ...
  else
    do_upstream_event(operation, upstream_data.id, upstream_data.name)
  end
end
-- 调用create_balancer
local function do_upstream_event(operation, upstream_id, upstream_name)
  if operation == "create" then
    ...
    local _, err = create_balancer(upstream)
    ...
  elseif operation == "delete" or operation == "update" then
	...
  end
end

--3. create_balancer实现如下：
  create_balancer = function(upstream, recreate, history, start)
   ...
    local balancer, err = create_balancer_exclusive(upstream, history, start)
    return balancer, err
  end
	--其最终调用的是/kong/runloop/balancer.lua的function create_balancer_exclusive
  local function create_balancer_exclusive(upstream, history, start)
    local health_threshold = upstream.healthchecks and
                              upstream.healthchecks.threshold or nil
	-- 这里，根据不同的balancer类型，执行其new方法，返回balancer实例
    local balancer, err = balancer_types[upstream.algorithm].new({
      log_prefix = "upstream:" .. upstream.name,
      wheelSize = upstream.slots,  -- will be ignored by least-connections
      dns = dns_client,
      healthThreshold = health_threshold,
    })
    ...
    target_histories[balancer] = {}
    ...
	-- 写入全局balancer
    set_balancer(upstream.id, balancer)
    return balancer
  end
  
--4. lb的balancer_types[upstream.algorithm]根据upstream的算法类型，返回lb对象，其type定义如下：
  local balancer_types = {
    ["consistent-hashing"] = require("resty.dns.balancer.ring"),
    ["least-connections"] = require("resty.dns.balancer.least_connections"),
    ["round-robin"] = require("resty.dns.balancer.ring"),
  }

```