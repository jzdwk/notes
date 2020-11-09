-- daos.lua, 顾名思义，用于定义和db对应的数据访问模型（schema），其作用和config的schema.lua类似
local typedefs = require "kong.db.schema.typedefs"

return {
  -- 定义和my_plugins对应的dao table, 这里建议使用复数，因为涉及到kong admin api的定义
  my_plugin_headers = {
    name                  = "my_plugin_headers", -- 定义在db中实际存储的table名称
    endpoint_key          = "header_key", --定义admin api访问时的url end point，默认使用xxx/my_plugin/{id}/xxx, 如果定义此项，可为xxx/my_plugin/{endpoint_key}/xxx
    primary_key           = { "id" },
    cache_key             = { "header_key","header_value" }, --定义kong缓存的key，
    generate_admin_api    = true, --是否生成admin api,默认将根据dao table生成
    admin_api_name        = "my_plg_headers", -- 自定义admin api url的endpoint,默认将使用dao table，my_plugin_headers，此处定义简写my_plg_headers
    admin_api_nested_name = "my_plg_header", -- 定义在一些嵌套场景下使用的api endpoint,比如当plugin和kong的其他对象有关联，去处理这些对象关联的plugin时使用，如xxx/router/{router_id}/my_plg_header
    -- 定义数据域,描述表的每一列    
    fields = {
      {
        -- id列
        id = typedefs.uuid,
      },
      {
        -- create_at列
        created_at = typedefs.auto_timestamp_s,
      },
      {
        -- 外键列
        route = {
          type      = "foreign",
          reference = "routes",
          default   = ngx.null,
          on_delete = "cascade",
        },
      },
      {
        -- header_key
        header_key = {
          type      = "string",
          required  = true,
          unique    = true,
          auto      = false,
        },
      },
      {
        -- header_value
        header_value = {
          type      = "string",
          required  = true,
          unique    = true,
          auto      = false,
        },
      },
    },
  },
}
