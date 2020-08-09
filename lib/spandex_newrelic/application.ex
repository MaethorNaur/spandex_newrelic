defmodule SpandexNewrelic.Application do
  use Application

  def start(_type, _args) do
    children = [
      %{
        id: SpandexNewrelic.ApiServer,
        start: {SpandexNewrelic.ApiServer, :start_link, []}
      }
    ]

    opts = [strategy: :one_for_one, name: SpandexNewrelic.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
