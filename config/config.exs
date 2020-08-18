import Config

config :spandex_newrelic,
  api_key: "",
  api_url: "https://trace-api.newrelic.com/trace/v1"

import_config "./#{Mix.env()}.exs"
