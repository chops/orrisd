defmodule AiPair.Test.OtelHelper do
  @moduledoc """
  Test scaffolding for asserting OpenTelemetry spans.

  Uses the upstream `:otel_simple_processor` with `:otel_exporter_pid` as
  the exporter. Each span is delivered to the configured pid as a `{:span,
  span}` message — assertions then pattern-match on `:span` record fields.

  ## Usage

      use ExUnit.Case, async: false  # the simple processor exporter is global

      import AiPair.Test.OtelHelper

      setup :setup_otel_capture

      test "emits a foo span" do
        # ...do work that emits a span...
        assert {:ok, span} = assert_span(name: "foo")
        assert span_name(span) == "foo"
        assert %{"foo.attr" => "bar"} = span_attrs(span)
      end

  Because the processor is global, **tests using this helper MUST run with
  `async: false`**.
  """

  require Record

  # Pull the :span record definition once at compile time. This is the
  # canonical Erlang record used by opentelemetry — field positions track
  # the otel SDK version, so let the compiler bind them.
  Record.defrecordp(
    :span_record,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @doc """
  Configure the simple processor to push spans into the calling test's
  mailbox via `:otel_exporter_pid`. Suitable as an ExUnit setup callback.
  """
  def setup_otel_capture(_context \\ %{}) do
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    ExUnit.Callbacks.on_exit(fn -> flush_spans() end)
    :ok
  end

  @doc "Drain all currently-buffered `{:span, _}` messages (oldest first)."
  def drain_spans(acc \\ []) do
    receive do
      {:span, span} -> drain_spans([span | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Drop any pending `{:span, _}` messages."
  def flush_spans do
    receive do
      {:span, _} -> flush_spans()
    after
      0 -> :ok
    end
  end

  @doc """
  Block up to `timeout` ms (default 200) for ONE span message that matches
  the given filter keyword list. Filters:

    * `:name` — exact-match the span name (binary)
    * `:span_id` / `:parent_span_id` / `:trace_id`
    * `:kind`

  Non-matching spans encountered while waiting are pushed back into the
  mailbox in original order. Returns `{:ok, span_record}` or
  `{:error, :timeout}`.
  """
  def assert_span(filters, timeout \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_span(filters, deadline, [])
  end

  defp do_assert_span(filters, deadline, requeue) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:span, span} = msg ->
        if matches?(span, filters) do
          Enum.each(Enum.reverse(requeue), fn m -> send(self(), m) end)
          {:ok, span}
        else
          do_assert_span(filters, deadline, [msg | requeue])
        end
    after
      remaining ->
        Enum.each(Enum.reverse(requeue), fn m -> send(self(), m) end)
        {:error, :timeout}
    end
  end

  @doc "Span name as a binary."
  def span_name(span), do: span_record(span, :name)

  @doc "Span id (integer)."
  def span_id(span), do: span_record(span, :span_id)

  @doc "Parent span id (integer) or `:undefined` for a root span."
  def parent_span_id(span), do: span_record(span, :parent_span_id)

  @doc "Trace id (integer)."
  def trace_id(span), do: span_record(span, :trace_id)

  @doc "Span kind (`:internal`, `:client`, `:server`, `:producer`, `:consumer`)."
  def span_kind(span), do: span_record(span, :kind)

  @doc "Span status — `{:status, code, message}` record-tuple from otel."
  def span_status(span), do: span_record(span, :status)

  @doc "Flat map of attributes (atom or binary keys → value)."
  def span_attrs(span) do
    case span_record(span, :attributes) do
      :undefined -> %{}
      nil -> %{}
      attrs -> :otel_attributes.map(attrs)
    end
  end

  defp matches?(span, filters) do
    Enum.all?(filters, fn
      {:name, name} -> span_name(span) == name
      {:span_id, id} -> span_id(span) == id
      {:parent_span_id, id} -> parent_span_id(span) == id
      {:trace_id, id} -> trace_id(span) == id
      {:kind, kind} -> span_kind(span) == kind
    end)
  end
end
