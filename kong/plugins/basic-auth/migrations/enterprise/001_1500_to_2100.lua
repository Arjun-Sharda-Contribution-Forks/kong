local operations = require "kong.enterprise_edition.db.migrations.operations.1500_to_2100"


local plugin_entities = {
  {
    name = "basicauth_credentials",
    primary_key = "id",
    uniques = {"username"},
    fks = {{name = "consumer", reference = "consumers", on_delete = "cascade"}},
  }
}


return operations.ws_migrate_plugin(plugin_entities)
