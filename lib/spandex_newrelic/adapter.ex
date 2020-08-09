defmodule SpandexNewrelic.Adapter do
  @moduledoc """
  A Datadog APM implementation for Spandex.
  """

  @behaviour Spandex.Adapter

  require Logger

  alias Spandex.{
    SpanContext,
    Tracer
  }


  @impl Spandex.Adapter
  def trace_id, do: UUID.uuid4()

  @impl Spandex.Adapter
  def span_id, do: trace_id()

  @impl Spandex.Adapter
  def now, do: :os.system_time(:nano_seconds)

  @impl Spandex.Adapter
  @spec default_sender() :: SpandexNewrelic.ApiServer
  def default_sender, do: SpandexNewrelic.ApiServer

  @doc """
  Fetches the Datadog-specific conn request headers if they are present.
  """
  @impl Spandex.Adapter
  @spec distributed_context(conn :: Plug.Conn.t(), Tracer.opts()) ::
          {:ok, SpanContext.t()}
          | {:error, :no_distributed_trace}
  def distributed_context(%Plug.Conn{} = conn, _opts) do
    trace_id = get_first_header(conn, "x-trace-id")
    parent_id = get_first_header(conn, "x-parent-id")
    priority = get_first_header(conn, "x-sampling-priority") || 1

    if is_nil(trace_id) || is_nil(parent_id) do
      {:error, :no_distributed_trace}
    else
      {:ok, %SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}}
    end
  end

  @impl Spandex.Adapter
  @spec distributed_context(headers :: Spandex.headers(), Tracer.opts()) ::
          {:ok, SpanContext.t()}
          | {:error, :no_distributed_trace}
  def distributed_context(headers, _opts) do
    trace_id = get_header(headers, "x-datadog-trace-id")
    parent_id = get_header(headers, "x-datadog-parent-id")
    priority = get_header(headers, "x-datadog-sampling-priority") || 1

    if is_nil(trace_id) || is_nil(parent_id) do
      {:error, :no_distributed_trace}
    else
      {:ok, %SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}}
    end
  end

  @doc """
  Injects Datadog-specific HTTP headers to represent the specified SpanContext
  """
  @impl Spandex.Adapter
  @spec inject_context(Spandex.headers(), SpanContext.t(), Tracer.opts()) :: Spandex.headers()
  def inject_context(headers, %SpanContext{} = span_context, _opts) when is_list(headers) do
    span_context
    |> tracing_headers()
    |> Kernel.++(headers)
  end

  def inject_context(headers, %SpanContext{} = span_context, _opts) when is_map(headers) do
    span_context
    |> tracing_headers()
    |> Enum.into(%{})
    |> Map.merge(headers)
  end

  # Private Helpers

  @spec get_first_header(Plug.Conn.t(), String.t()) :: integer() | nil
  defp get_first_header(conn, header_name) do
    conn
    |> Plug.Conn.get_req_header(header_name)
    |> List.first()
    |> parse_header()
  end

  @spec get_header(%{}, String.t()) :: integer() | nil
  defp get_header(headers, key) when is_map(headers) do
    Map.get(headers, key, nil)
    |> parse_header()
  end

  @spec get_header([], String.t()) :: integer() | nil
  defp get_header(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if k == key, do: v end)
    |> parse_header()
  end

  defp parse_header(header) when is_bitstring(header) do
    case Integer.parse(header) do
      {int, _} -> int
      _ -> nil
    end
  end

  defp parse_header(_header), do: nil

  defp tracing_headers(%SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}) do
    [
      {"x-trace-id", to_string(trace_id)},
      {"x-parent-id", to_string(parent_id)},
      {"x-sampling-priority", to_string(priority)}
    ]
  end
end
