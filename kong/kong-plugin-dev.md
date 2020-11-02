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
├── api.lua #非必须，定义插件实体的crud api，
├── daos.lua #非必须，定义实体的抽象，即所需实体的表对应的实体
├── handler.lua #必须，kong定义了一组需要实现的接口，这些接口体现了从request到response的各个阶段。通过在handler.lua中去实现这些接口，完成插件的具体处理逻辑。
├── migrations #非必须，定义了实体后，migrations用于进行DB的操作，如创建表等
│   ├── init.lua
│   └── 000_base_complete_plugin.lua
└── schema.lua #必须，定义了这个插件中可以配置的项，比如(route,service,config以及config中的各个项)，以及这些项的约束，比如必须数字、必须为HTTP 方法等等。
```

## 例子
开发个插件，应用在service或者route上，要求请求的header上必须携带一个[k,v]对，这个k,v对为在config中配置的给定值

## schema

## handler

## phrase to impl

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

3. 执行`luarocks make`

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