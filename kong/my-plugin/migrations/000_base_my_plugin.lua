return {
  -- postgres define
  postgres = {
    -- up parse, create table
    up = [[
      CREATE TABLE IF NOT EXISTS "my_plugin_headers" (
		"id" uuid NOT NULL,
		"create_at" timestamptz,
		"route_id" uuid REFERENCES "routes" ("id") ON DELETE CASCADE,
		"header_key" varchar(20),
		"header_value" varchar(20),
		PRIMARY KEY ("id"));
    ]],
  },
}