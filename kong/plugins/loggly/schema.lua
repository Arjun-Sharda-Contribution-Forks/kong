-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"

local severity = {
  type = "string",
  default = "info",
  one_of = { "debug", "info", "notice", "warning", "err", "crit", "alert", "emerg" },
}

return {
  name = "loggly",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { host = typedefs.host({ default = "logs-01.loggly.com" }), },
          { port = typedefs.port({ default = 514 }), },
          { key = { type = "string", required = true }, },
          { tags = {
              type = "set",
              default = { "kong" },
              elements = { type = "string" },
          }, },
          { log_level = severity },
          { successful_severity = severity },
          { client_errors_severity = severity },
          { server_errors_severity = severity },
          { timeout = { type = "number", default = 10000 }, },
          { custom_fields_by_lua = typedefs.lua_code },
        },
      },
    },
  },
}
