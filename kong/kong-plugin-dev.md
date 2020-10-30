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