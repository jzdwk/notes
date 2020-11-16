package = "kong-plugin-my-plugin"
version = "0.0.1-1"

source = {
  url = "https://github.com/jzdwk/notes/tree/master/kong/my-plugin",
  tag = "v0.0.1-1"
}

supported_platforms = {"linux"}

description = {
  summary = "My Plugin",
}

dependencies = {
   "lua >= 5.1"
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.my-plugin.handler"] = "handler.lua",
    ["kong.plugins.my-plugin.schema"] = "schema.lua",
    ["kong.plugins.my-plugin.daos"] = "daos.lua",

    ["kong.plugins.my-plugin.migrations.init"] = "migrations/init.lua",
    ["kong.plugins.my-plugin.migrations.000_base_my_plugin"] = "migrations/000_base_my_plugin.lua",
  }
}
