# kong plugin 插件开发笔记

## lua传送门

https://www.runoob.com/lua/lua-tutorial.html

## 结构划分

kong插件的lua module按照：
```lua
kong.plugins.<plugin_name>.<module_name>
```
定义，其中的`plugin_name`项即为插件安装时,在kong.conf文件中，plugins项的名称：
```shell
plugins = custom-plugin # your plugin name here
```

一个kong插件的完成目录结构为：
```shell
complete-plugin #插件文件
├── api.lua #非必需，定义插件实体的crud api，
├── daos.lua #非必需，定义实体的抽象，即所需实体的表对应的实体
├── handler.lua #必需，kong定义了一组需要实现的接口，这些接口体现了从request到response的各个阶段。通过在handler.lua中去实现这些接口，完成插件的具体处理逻辑。
├── migrations #非必需，定义了实体后，migrations用于进行DB的操作，如创建表等
│   ├── init.lua
│   └── 000_base_complete_plugin.lua
└── schema.lua #必需，定义了这个插件中可以配置的项，比如(route,service,config以及config中的各个项)，以及这些项的约束，比如必须数字、必须为HTTP 方法等等。
```

## 目标1

开发个插件my-plugin，应用在service或者route上，要求请求的header上必须携带一个`k,v`对，这个`k,v`对为在config中配置的给定值

### schema
`schema.lua`文件的作用为定义plugin的数据配置结构，从而使其可以在admin api中被创建，比如：
```shell
# name和config.foo都是在schema中定义的
curl -X POST http://kong:8001/services/<service-name-or-id>/plugins \
    -d "name=my-custom-plugin" \
    -d "config.foo=bar"
```
其最主要的三个部分是：
1. name，string类型，定义plugin的名称
2. fields，table类型，定义插件需要配置的**所有数据项**，即在插件的crud请求中，body里携带的内容的定义
3. entity_checks， function类型，实体可用性检查的数据

其中的fields又存在几个默认的内置项，包括了：`id, name, created_at, route, service ,consumer, protocols, enabled, tags`

schema.lua文件的模板如下：
```lua
-- 引入typedefs
local typedefs = require "kong.db.schema.typedefs"
-- 定义plugin的schema
return {
  -- 1. plugin name
  name = "<plugin-name>",
  -- 2. 定义数据域
  fields = {
    -- 2.1 plugin存在默认的fields项，默认plugin可以应用在route service consumer
    {
      -- this plugin will only be applied to Services or Routes
      consumer = typedefs.no_consumer
    },
	-- 2.2 plugin存在默认的fields项
    {
      -- this plugin will only run within Nginx HTTP module
      protocols = typedefs.protocols_http
    },
	-- 2.n 重要，config项，插件的自定义的fields都在此完成
    {
      config = {
        type = "record",
		-- 2.n.1 定义config中的第一项，嵌套结构，
        fields = {
          -- Describe your plugin's configuration's schema here.        
        },
		-- 2.n.m 定义config中的第y项
		-- xxx
      },
    },
  },
  -- 3. 定义实体检查
  entity_checks = {
    -- Describe your plugin's entity validation rules
  },
}
```
比如按照*目标1*的需求，定义的schema.lua文件如下：
```lua
local typedefs = require "kong.db.schema.typedefs"

-- define my plugin schema
return {
  name = "my-plugin",
  fields = {
    {-- 默认plugin可以应用在service/route以及consumer,此处声明这个plugin只能应用在service/route
      consumer = typedefs.no_consumer},
    {-- 只支持http
      protocols = typedefs.protocols_http
    },
    {
	  --plugin的config中的子项定义 
      config = {
        type = "record",
        fields = {
          -- 定义 plugin的可配置项，第一个配置，config.header_key
		  {
            header_key = {
              type = "string",
              required = true,
            },
          },
		  -- 定义 plugin的可配置项，第二个配置，config.header_value
          {
            header_value = {
              type = "string",
              required = true,
            },
          },
        },
      },
    },
  }
}
```

### handler

`handler.lua`的作用为**实现用户自定义的插件逻辑**，该文件是实现plugin的核心文件。实现plugin的方式为，重写kong定义的在处理http请求的8个接口，这些接口位于[openResty lua-nginx-module](https://github.com/openresty/lua-nginx-module) 的不同阶段，在**HTTP/s 上编写的插件**接口包括了：

1. :init_worker()，[init_worker 阶段](https://github.com/openresty/lua-nginx-module#init_worker_by_lua) 当Nginx的worker process启动时执行。

2. :certificate()，[ssl_certificate 阶段](https://github.com/openresty/lua-nginx-module#ssl_certificate_by_lua_block) 	在使用SSL证书进行SSL握手时执行。

3. :rewrite()，[rewrite 阶段](https://github.com/openresty/lua-nginx-module#rewrite_by_lua_block) 在kong接收了客户端的请求，进行rewrite时执行. 因为**这个阶段，kong仅刚刚接收了请求，并没有识别出请求对应的service/consumer**,因此，如果plugin重写了该阶段，则此插件只能被配置为**全局插件**。

4. :access()，[access 阶段](https://github.com/openresty/lua-nginx-module#access_by_lua_block) 当kong接收了该请求，并在其将请求代理到上游(upstream)服务之前执行。大多数的plugin均在该接口实现核心业务逻辑。

5. :response()，[access 阶段](https://github.com/openresty/lua-nginx-module#access_by_lua_block)， 当kong接收了上游服务的response后，但还没有将其发送给client时执行。**这个接口的功能和接下来的header_filter body_filter有重叠，因此如果一个plugin同时重写了response(),header_filter()或body_filter()，将无法启动kong。**

6. :header_filter()，[header_filter 阶段](https://github.com/openresty/lua-nginx-module#header_filter_by_lua_block), 当kong接收了所有的上游服务返回的response header后执行。

7. :body_filter()，[body_filter 阶段](https://github.com/openresty/lua-nginx-module#body_filter_by_lua_block)  每一次kong从上游服务的response body中接收chunk，  实现这个接口的func就被执行一次。

8. :log()，[log 阶段](https://github.com/openresty/lua-nginx-module#log_by_lua_block) 当kong将响应全部发送给client后执行。

而在**TCP/UDP上编写的插件**接口包括了：

1. :init_worker() [init_worker 阶段](https://github.com/openresty/lua-nginx-module#init_worker_by_lua) 当Nginx的worker process启动时执行。

2. :preread()，[preread 阶段](https://github.com/openresty/stream-lua-nginx-module#preread_by_lua_block) 建立连接时执行

3. :log()，[log 阶段](https://github.com/openresty/lua-nginx-module#log_by_lua_block) 当kong将响应全部发送给client后执行。

所以根据插件的业务需求，在`handler.lua`中，需要返回一个实现了对应接口的table，其模板如下:
```lua
-- Extending the Base Plugin handler is optional, as there is no real
-- concept of interface in Lua, but the Base Plugin handler's methods
-- can be called from your child implementation and will print logs
-- in your `error.log` file (where all logs are printed).
local BasePlugin = require "kong.plugins.base_plugin"
-- CustomHandler即自定义的插件table
local CustomHandler = BasePlugin:extend()

CustomHandler.VERSION  = "1.0.0"

-- 由于kong支持多个plugin，而且某些plugin的执行依赖于另一些plugin，因此存在一个执行顺序，此设置用于配置plugin的执行优先级，越大越高。
-- 详细参考：https://docs.konghq.com/2.2.x/plugin-development/custom-logic/#plugins-execution-order
CustomHandler.PRIORITY = 10

-- Your plugin handler's constructor. If you are extending the
-- Base Plugin handler, it's only role is to instantiate itself
-- with a name. The name is your plugin name as it will be printed in the logs.
function CustomHandler:new()
  CustomHandler.super.new(self, "my-custom-plugin")
end

-- 如果需要，重写各个接口，下同
function CustomHandler:init_worker()
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  CustomHandler.super.init_worker(self)

  -- Implement any custom logic here
end

--- 省略。。。

function CustomHandler:access(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  CustomHandler.super.access(self)

  -- Implement any custom logic here
end

-- 重要，返回这个table
return CustomHandler
```
以目标1的需求为例子，其handler的核心代码为：
```lua

-- 上面省略...

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
    -- 如果验证失败，调用PDK返回
    kong.response.error(401,"undefined header in request")
  end
  kong.log.debug("[my-plugin] spend time : " .. os.clock() - start_time .. ".")
end

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
```

另外，可以将plugin的核心逻辑移入自定义的module，并将其引入handler，从而提高代码可读性：
```lua
local BasePlugin = require "kong.plugins.base_plugin"

-- 进入两个自定义的moduler,分别为access和body_filter
local access = require "kong.plugins.my-custom-plugin.access"
local body_filter = require "kong.plugins.my-custom-plugin.body_filter"


local CustomHandler = BasePlugin:extend()

function CustomHandler:new()
  CustomHandler.super.new(self, "my-custom-plugin")
end

function CustomHandler:access(config)
  CustomHandler.super.access(self)

  -- 从引入的access module中执行对应函数
  access.execute(config)
end

function CustomHandler:body_filter(config)
  CustomHandler.super.body_filter(self)
   -- 从引入的body_filter module中执行对应函数
  body_filter.execute(config)
end
return CustomHandler
```

在实现插件业务的过程中，必然存在诸如*获取请求详细信息*等需要kong交互接口实现，因此，Kong提供了一套[Kong Plugin Development Kit] (https://docs.konghq.com/2.2.x/pdk/) 供调用。

至此，针对目标1的简单的plugin已经实现完毕。当定义的plugin需要和kong的db等或扩展admin api(比如提供 /kong:8001/my-plugin api)，则需要定义额外

## 目标2

在目标1中，完成了简单的根据plugin的config，从request（route/service）中过滤请求，执行handler的逻辑。假设现在需要kong去持久化一些数据，并将这些数据绑定在某个kong的资源对象上，当request到达时，需要对请求中携带的信息以及持久化的数据，使用lua脚本编写的逻辑进行验证（比如鉴权）。则需要kong的db/migration/dao参与。

- **目标2**：继续扩展插件my-plugin，应用在service或者route上，要求请求的header上必须携带一个`k,v`对，这个`k,v`对为在config中配置的给定值，此为请求的过滤条件。当达到条件后，再根据这个k,v对，去判断该k,v对是否已经绑定在了所请求的route对象上，如果绑定，则通过，否则失败。

### migration

当开发的插件需要用到kong的db去存储数据，则需要扩展kong的db层，增加额外的表，即migration需要做的工作。首先：

1. 在插件所在目录下，创建子目录以及init文件`migrations/init.lua`，这个lua文件用于描述migrations需要的lua脚本文件（即dB中的表定义等内容）,如果migration进行了升级，则需要在此后追加修改脚本，而不是覆盖原有脚本：
```lua
-- `migrations/init.lua`
return {
  -- 最初版lua脚本
  "000_base_my_plugin",
  -- 从100版本升级到了110,文件格式推荐为：序号_旧版本_to_新版本
  "001_100_to_110",
}
```

2. 继续在`migrations`目录下，创建db描述脚本，比如`000_base_my_plugin`，它的主要作用就是描述扩展的plugin的db表。具体的migration脚本的模板格式如下:
```lua
-- `<plugin_name>/migrations/000_base_my_plugin.lua`
return {
  -- db为postges的配置
  postgresql = {
    -- up项表示，当kong执行db初始化时执行的语句
    up = [[
      CREATE TABLE IF NOT EXISTS "my_plugin_table" (
        "id"           UUID                         PRIMARY KEY,
        "created_at"   TIMESTAMP WITHOUT TIME ZONE,
        "col1"         TEXT
      );
    
      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "my_plugin_table_col1"
                                ON "my_plugin_table" ("col1");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },
  --db为cassandra的配置
  cassandra = {
    -- 同理于上面up项所述
    up = [[
      CREATE TABLE IF NOT EXISTS my_plugin_table (
        id          uuid PRIMARY KEY,
        created_at  timestamp,
        col1        text
      );
      
      CREATE INDEX IF NOT EXISTS ON my_plugin_table (col1);
    ]],
  }
}
```
同样的，在执行版本升级时，migration脚本模板如下：
```lua
-- `<plugin_name>/migrations/001_100_to_110.lua`
return {
  postgresql = {
    up = [[
      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY "my_plugin_table" ADD "cache_key" TEXT UNIQUE;
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END;
    $$;
    ]],
	-- teardown项用于描述 当kong执行完成db初始化后，执行的语句，和up搭配使用
    teardown = function(connector, helpers)
      assert(connector:connect_migrations())
      assert(connector:query([[
	    -- 具体的SQL语句
        DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "my_plugin_table" DROP "col1";
        EXCEPTION WHEN UNDEFINED_COLUMN THEN
          -- Do nothing, accept existing state
        END$$;
      ]])
    end,
  },

  cassandra = {
    up = [[
      ALTER TABLE my_plugin_table ADD cache_key text;
      CREATE INDEX IF NOT EXISTS ON my_plugin_table (cache_key);
    ]],
	-- 同上 teardown描述
    teardown = function(connector, helpers)
      assert(connector:connect_migrations())
      assert(connector:query("ALTER TABLE my_plugin_table DROP col1"))
    end,
  }
}
```

## install

当代码编辑完成后，将插件安装在kong上，官方推荐使用[luarocks](https://luarocks.org) 工具.

1. 首先，在插件的本地目录编辑一个`rockspec`文件，文件内容的模板为，[参考](https://github.com/Kong/kong-plugin/blob/master/kong-plugin-myplugin-0.1.0-1.rockspec)：
```
package = "kong-plugin-myplugin"  -- TODO: rename, must match the info in the filename of this rockspec!
                                  -- as a convention; stick to the prefix: `kong-plugin-`
version = "0.1.0-1"               -- TODO: renumber, must match the info in the filename of this rockspec!
-- The version '0.1.0' is the source code version, the trailing '1' is the version of this rockspec.
-- whenever the source version changes, the rockspec should be reset to 1. The rockspec version is only
-- updated (incremented) when this file changes, but the source remains the same.

-- TODO: This is the name to set in the Kong configuration `plugins` setting.
-- Here we extract it from the package name.
local pluginName = package:match("^kong%-plugin%-(.+)$")  -- "myplugin"

supported_platforms = {"linux", "macosx"}
source = {
  url = "http://github.com/Kong/kong-plugin.git",
  tag = "0.1.0"
}

description = {
  summary = "Kong is a scalable and customizable API Management Layer built on top of Nginx.",
  homepage = "http://getkong.org",
  license = "Apache 2.0"
}

dependencies = {
}

build = {
  type = "builtin",
  modules = {
    -- TODO: add any additional files that the plugin consists of
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
  }
}
```
以`request-trans`插件为例子，其spec如下：
```
package = "kong-plugin-argonath-request-transformer"
version = "0.1.0-1"

source = {
  url = "git://github.com/tyler-cloud-elements/kong-plugin-request-transformer",
  tag = "v0.1.0"
}

supported_platforms = {"linux", "macosx"}
description = {
  summary = "Cloud Elements Argonath Request Transformer Plugin",
}

dependencies = {
   "lua >= 5.1"
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.argonath-request-transformer.migrations.cassandra"] = "kong/plugins/argonath-request-transformer/migrations/cassandra.lua",
    ["kong.plugins.argonath-request-transformer.migrations.postgres"] = "kong/plugins/argonath-request-transformer/migrations/postgres.lua",
    ["kong.plugins.argonath-request-transformer.migrations.common"] = "kong/plugins/argonath-request-transformer/migrations/common.lua",
    ["kong.plugins.argonath-request-transformer.handler"] = "kong/plugins/argonath-request-transformer/handler.lua",
    ["kong.plugins.argonath-request-transformer.access"] = "kong/plugins/argonath-request-transformer/access.lua",
    ["kong.plugins.argonath-request-transformer.schema"] = "kong/plugins/argonath-request-transformer/schema.lua",
  }
}
```

2. 在插件的本地目录中，创建按spec描述的目录结构，并将代码放入：
```shell
|my-plugin
├── kong  #主要为此目录
│   └── plugins
│       └── my-plugin
│           ├── handler.lua
│           └── schema.lua
├── kong-plugin-my-plugin-0.0.1-1.rockspec
```

3. 执行`luarocks make`,此步执行完后，会在目录`/usr/local/lib/luarocks/rocks-5.1`中，添加名为`kong-plugin-my-plugin`的目录。

4. 以上为本地plugin源码安装，也可以将其打包为：
```shell
# pack the installed rock
$ luarocks pack <plugin-name> <version>
# 比如
luarocks pack kong-plugin-my-plugin 0.0.1-1
# 此时将生成 类似kong-plugin-my-plugin-0.0.1-1.all.rock
# 执行
luarocks install kong-plugin-my-plugin-0.0.1-1.all.rock
```
执行后，同样会在`/usr/local/lib/luarocks/rocks-5.1`中，添加名为`kong-plugin-my-plugin`的目录。

5. 进入kong的配置文件目录，默认位于`/etc/kong/xxx.conf`,修改conf文件的plugins项：
```
# bundled表是安装kong默认的插件

plugins = bundled,<plugin-name>

```
6. 重启/reload kong
```
# reload
kong prepare
kong reload -c xxx.conf
# restart
kong restart -c xxx.conf
```

## uninstall

卸载插件需要3步：

1. 清理已经在kong上应用的插件，即访问`{admin}/plugins`的DELETE方法，删除之

2. 清理kong.conf中的plugins项，将添加的自定义插件删除，然后reload/restart之

3. 使用`luarocks remove <kong-plugin-plugin-name>`，删除在目录`/usr/local/lib/luarocks/rocks-5.1`中添加的自定义插件目录。