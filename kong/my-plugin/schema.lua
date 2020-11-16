local typedefs = require "kong.db.schema.typedefs"

-- define my plugin schema
return {
  name = "my-plugin",
  fields = {
    {-- 默认plugin可以应用在service/route以及consumer,此处声明这个plugin只能应用在service/route
    consumer = typedefs.no_consumer},
    {-- 支持http
      protocols = typedefs.protocols_http
    },
    {
     --plugin的config中的子项定义 
     config = {
      type = "record",
      fields = {
        -- 定义 plugin的可配置项
        {
          header_key = {
            type = "string",
            required = true,
          },
        },
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