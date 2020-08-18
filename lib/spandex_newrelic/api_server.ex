defmodule SpandexNewrelic.ApiServer do
  use GenServer
  require Logger

  @api_url Application.fetch_env!(:spandex_newrelic, :api_url)

  @headers [
    {"Content-Type", "application/json"},
    {"Data-Format", "newrelic"},
    {"Data-Format-Version", "1"}
  ]

  alias Spandex.{
    Span,
    Trace
  }

  defmodule State do
    @moduledoc false

    @type t :: %State{}

    defstruct [
      :asynchronous_send?,
      :verbose?,
      :waiting_traces,
      :batch_size,
      :sync_threshold,
      :agent_pid
    ]
  end

  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, agent_pid} = Agent.start_link(fn -> 0 end, name: :spandex_currently_send_count)

    state = %State{
      asynchronous_send?: true,
      verbose?: Keyword.get(opts, :verbose?, false),
      waiting_traces: [],
      batch_size: Keyword.get(opts, :batch_size, 10),
      sync_threshold: Keyword.get(opts, :sync_threshold, 20),
      agent_pid: agent_pid
    }

    {:ok, state}
  end

  @doc """
  Send spans asynchronously to DataDog.
  """
  @spec send_trace(Trace.t(), Keyword.t()) :: :ok
  def send_trace(%Trace{} = trace, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:send_trace, trace}, timeout)
  end

  @deprecated "Please use send_trace/2 instead"
  @doc false
  @spec send_spans([Span.t()], Keyword.t()) :: :ok
  def send_spans(spans, opts \\ []) when is_list(spans) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    trace = %Trace{spans: spans}
    GenServer.call(__MODULE__, {:send_trace, trace}, timeout)
  end

  @doc false
  def handle_call(
        {:send_trace, trace},
        _from,
        %State{waiting_traces: waiting_traces, batch_size: batch_size, verbose?: verbose?} = state
      )
      when length(waiting_traces) + 1 < batch_size do
    if verbose? do
      Logger.info(fn -> "Adding trace to stack with #{Enum.count(trace.spans)} spans" end)
    end

    {:reply, :ok, %{state | waiting_traces: [trace | waiting_traces]}}
  end

  def handle_call(
        {:send_trace, trace},
        _from,
        %State{
          verbose?: verbose?,
          asynchronous_send?: asynchronous?,
          waiting_traces: waiting_traces,
          sync_threshold: sync_threshold,
          agent_pid: agent_pid
        } = state
      ) do
    all_traces = [trace | waiting_traces]

    if verbose? do
      trace_count = length(all_traces)

      span_count = Enum.reduce(all_traces, 0, fn trace, acc -> acc + length(trace.spans) end)

      Logger.info(fn -> "Sending #{trace_count} traces, #{span_count} spans." end)

      Logger.debug(fn -> "Trace: #{inspect(all_traces)}" end)
    end

    if asynchronous? do
      below_sync_threshold? =
        Agent.get_and_update(agent_pid, fn count ->
          if count < sync_threshold do
            {true, count + 1}
          else
            {false, count}
          end
        end)

      if below_sync_threshold? do
        Task.start(fn ->
          try do
            send_and_log(all_traces, state)
          after
            Agent.update(agent_pid, fn count -> count - 1 end)
          end
        end)
      else
        # We get benefits from running in a separate process (like better GC)
        # So we async/await here to mimic the behavour above but still apply backpressure
        task = Task.async(fn -> send_and_log(all_traces, state) end)
        Task.await(task)
      end
    else
      send_and_log(all_traces, state)
    end

    {:reply, :ok, %{state | waiting_traces: []}}
  end

  @spec send_and_log([Trace.t()], State.t()) :: :ok
  def send_and_log(traces, %{verbose?: verbose?}) do
    response =
      traces
      |> Enum.map(&format/1)
      |> encode()
      |> push(headers())

    if verbose? do
      Logger.debug(fn -> "Trace response: #{inspect(response)}" end)
    end

    :ok
  end

  @deprecated "Please use format/3 instead"
  @spec format(Trace.t()) :: map()
  def format(%Trace{spans: spans, priority: priority, baggage: baggage}) do
    common = common_map(spans)
    spans = Enum.map(spans, fn span -> format(span, priority, baggage) end)
    %{"common" => common, "spans" => spans}
  end

  @spec format(Span.t(), integer(), Keyword.t()) :: map()
  def format(%Span{} = span, _priority, _baggage) do
    attributes =
      %{
        "name" => "#{span.name} #{span.resource}",
        "resource" => span.resource || span.name,
        "service.name" => span.service,
        "parent.id" => span.parent_id,
        "type" => span.type,
        "duration.ms" =>
          ((span.completion_time || SpandexNewrelic.Adapter.now()) - span.start) / 1_000_000
      }
      |> add_error_data(span)
      |> add_sql_data(span)
      |> add_http_data(span)
      |> add_tags(span)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    %{
      "trace.id" => span.trace_id,
      "id" => span.id,
      "timestamp" => (span.start / 1_000_000) |> Float.ceil() |> trunc(),
      "attributes" => attributes
    }
  end

  defp headers, do: [{"Api-Key", api_key()} | @headers]
  defp api_key, do: Application.fetch_env!(:spandex_newrelic, :api_key)

  defp common_map([%{env: env} | _tail]) do
    {:ok, hostname} = :inet.gethostname()
    %{"attributes" => %{"environment" => env, "host" => to_string(hostname)}}
  end

  @spec add_error_data(map, Span.t()) :: map
  defp add_error_data(meta, %{error: nil}), do: meta

  defp add_error_data(meta, %{error: error}) do
    meta
    |> add_error_message(error[:exception])
  end

  @spec add_error_message(map, Exception.t() | nil) :: map
  defp add_error_message(meta, nil), do: meta

  defp add_error_message(meta, exception),
    do:
      Map.put(meta, "error.message", Exception.message(exception))
      |> Map.put("error", true)

  @spec add_http_data(map, Span.t()) :: map
  defp add_http_data(meta, %{http: nil}), do: meta

  defp add_http_data(meta, %{http: http}),
    do:
      meta
      |> Map.put("request.url", http[:url])
      |> Map.put("response.statusCode", http[:status_code])
      |> Map.put("request.method", http[:method])

  @spec add_sql_data(map, Span.t()) :: map
  defp add_sql_data(meta, %{sql_query: nil}), do: meta

  defp add_sql_data(meta, %{sql_query: sql}) do
    meta
    |> Map.put("db.query", sql[:query])
    |> Map.put("db.count", sql[:rows])
    |> Map.put("db.name", sql[:db])
  end

  @spec add_tags(map, Span.t()) :: map
  defp add_tags(meta, %{tags: nil}), do: meta

  defp add_tags(meta, %{tags: tags}),
    do:
      Map.merge(
        meta,
        tags
        |> Enum.map(fn {k, v} -> {k, term_to_string(v)} end)
        |> Enum.into(%{})
      )

  @spec encode(data :: term) :: iodata | no_return
  defp encode(data),
    do: data |> deep_remove_nils() |> Jason.encode!()

  @spec push(body :: iodata(), Spandex.headers()) :: any()
  defp push(body, headers),
    do: Mojito.post(@api_url, headers, body)

  @spec deep_remove_nils(term) :: term
  defp deep_remove_nils(term) when is_map(term) do
    term
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    |> Enum.into(%{})
  end

  defp deep_remove_nils(term) when is_list(term) do
    if Keyword.keyword?(term) do
      term
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    else
      Enum.map(term, &deep_remove_nils/1)
    end
  end

  defp deep_remove_nils(term), do: term

  defp term_to_string(term) when is_binary(term), do: term
  defp term_to_string(term) when is_atom(term), do: term
  defp term_to_string(term), do: inspect(term)
end
