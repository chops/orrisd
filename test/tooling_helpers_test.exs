ExUnit.start()
Code.require_file("../nix/files/tooling.ex", __DIR__)
Code.require_file("../nix/files/telemetry-batch.ex", __DIR__)

defmodule ToolingHelpersTest do
  use ExUnit.Case, async: true
  alias AiPair.{TelemetryBatch, Tooling}

  defp auth(expiry) do
    payload = JSON.encode!(%{"exp" => expiry}) |> Base.url_encode64(padding: false)
    JSON.encode!(%{"tokens" => %{"access_token" => "header.#{payload}.signature"}})
  end

  test "token warning boundaries remain exact and parsing failures stay unknown" do
    assert Tooling.token_expiry(auth(999), 1000) == "expired"
    assert Tooling.token_expiry(auth(1000), 1000) == "expired"
    assert Tooling.token_expiry(auth(1001), 1000) == "soon"
    assert Tooling.token_expiry(auth(4599), 1000) == "soon"
    assert Tooling.token_expiry(auth(4600), 1000) == "ok"
    assert Tooling.token_expiry(auth("4600"), 1000) == "unknown"
    assert Tooling.token_expiry("not json", 1000) == "unknown"
    assert Tooling.token_expiry(~s({"tokens":null}), 1000) == "unknown"
    assert Tooling.token_expiry(~s({"tokens":{"access_token":"bad"}}), 1000) == "unknown"
  end

  test "nested JSON lookup preserves false, zero, empty and escaped strings" do
    value = %{"routes" => %{"quoted\"host" => %{"port" => 0, "user" => "", "flag" => false}}}
    assert Tooling.get_path(value, ["routes", "quoted\"host", "port"]) == 0
    assert Tooling.get_path(value, ["routes", "quoted\"host", "user"]) == ""
    assert Tooling.get_path(value, ["routes", "quoted\"host", "flag"]) == false
    assert Tooling.get_path(value, ["routes", "missing"]) == nil
    assert Tooling.get_path(value, ["routes", "quoted\"host", "port", "invalid"]) == nil
  end

  test "provider discovery preserves fallback and future names deterministically" do
    assert TelemetryBatch.providers(%{}) == ["anthropic", "openai-codex"]

    assert TelemetryBatch.providers(%{
             "tagValues" => ["vertex", %{"value" => "quoted\"provider"}, "vertex", " "]
           }) ==
             ["anthropic", "openai-codex", "quoted\"provider", "vertex"]
  end

  test "selection reserves one provider then fills globally and breaks ties by id" do
    rows = [
      {"400", "a", "anthropic", "a"},
      {"400", "b", "anthropic", "b"},
      {"100", "c", "other", "c"}
    ]

    assert TelemetryBatch.select(rows, 2) == [List.last(rows), hd(rows)]
    assert TelemetryBatch.select(rows, 1) == [hd(rows)]
    assert TelemetryBatch.select(rows, 3) == [List.last(rows), hd(rows), Enum.at(rows, 1)]
    assert TelemetryBatch.provider_summary(rows) == "anthropic=2, openai-codex=0, other=1"
  end

  test "null and non-list provider collections retain fallback providers" do
    for value <- [nil, true, 7, "not a collection", %{}] do
      assert TelemetryBatch.providers(%{"tagValues" => value}) == ["anthropic", "openai-codex"]
    end
  end

  test "missing, null and non-list trace collections are empty without hiding valid rows" do
    assert TelemetryBatch.candidates(%{}) == []

    for value <- [nil, true, 7, "not a collection", %{}] do
      assert TelemetryBatch.candidates(%{"traces" => value}) == []
    end

    assert TelemetryBatch.candidates(%{
             "traces" => [nil, %{}, %{"startTimeUnixNano" => "123", "traceID" => "fixture"}]
           }) == [{"123", "fixture"}]
  end

  test "timestamp ordering preserves the prior lexical sort, not numeric sorting" do
    rows = [{"10", "a", "same", ""}, {"9", "b", "same", ""}]
    assert TelemetryBatch.select(rows, 1) == [List.last(rows)]
  end

  test "candidate timestamps render JSON values without changing integers or strings" do
    rows =
      Enum.map([%{"value" => 1}, true, false, nil, 123, "456"], fn value ->
        %{"startTimeUnixNano" => value, "traceID" => "fixture"}
      end)

    assert TelemetryBatch.candidates(%{"traces" => rows}) ==
             Enum.map([~s({"value":1}), "true", "false", "null", "123", "456"], fn value ->
               {value, "fixture"}
             end)
  end

  test "JSON command reads structured input and retains route/get defaults" do
    import ExUnit.CaptureIO

    assert capture_io(~s({"routes":{"quoted\\"host":{"port":0}}}), fn ->
             Tooling.main(["route", "quoted\"host"])
           end) == "{\"port\":0}\n"

    assert capture_io(~s({"value":false}), fn -> Tooling.main(["get", "fallback", "value"]) end) ==
             "fallback\n"

    assert capture_io(~s({"value":0}), fn -> Tooling.main(["get", "fallback", "value"]) end) ==
             "0\n"

    assert capture_io(~s({"value":""}), fn -> Tooling.main(["get", "fallback", "value"]) end) ==
             "\n"

    assert_raise JSON.DecodeError, fn ->
      capture_io("not JSON", fn -> Tooling.main(["get", "fallback", "value"]) end)
    end
  end

  defp trace(attrs) do
    %{"batches" => [%{"scopeSpans" => [%{"spans" => [%{"attributes" => attrs}]}]}]}
  end

  defp attr(key, value), do: %{"key" => key, "value" => %{"stringValue" => value}}

  test "extraction keeps first provider admission and last attribute rendering" do
    attrs = [
      attr("gen_ai.system", "anthropic"),
      attr("http.request.method", "POST"),
      attr("gen_ai.system", "other"),
      attr("ai_pair.harness", "fallback"),
      attr("gen_ai.prompt", String.duplicate("x", 801)),
      attr("gen_ai.completion", "response")
    ]

    assert {:ok, "anthropic", summary} = TelemetryBatch.extract(trace(attrs), "id")
    assert summary =~ "provider: other\n"
    assert summary =~ "agent: fallback\n"
    assert summary =~ String.duplicate("x", 800)
    refute summary =~ String.duplicate("x", 801)
    assert summary =~ "--- RESPONSE PREVIEW ---\nresponse"
  end

  test "non-POST, missing provider and malformed traces are not extractable" do
    assert TelemetryBatch.extract(
             trace([attr("gen_ai.system", "other"), attr("http.request.method", "GET")]),
             "id"
           ) == :skip

    assert TelemetryBatch.extract(trace([attr("http.request.method", "POST")]), "id") == :skip
    assert TelemetryBatch.extract(%{"batches" => nil}, "id") == :skip
    assert TelemetryBatch.extract(%{}, "id") == :skip
  end

  test "managed block replacement preserves prior exact-line and repeated-marker behavior" do
    dir = Path.join(System.tmp_dir!(), "managed-block-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    body = Path.join(dir, "body")
    target = Path.join(dir, "target")
    File.write!(body, "new\\literal\nlast")
    File.write!(target, "before\nBEGIN\nold\nEND\nmiddle\nBEGIN\nsecond\nEND\nafter")
    helper = Path.expand("../nix/files/managed-block.sh", __DIR__)

    assert {"before\nBEGIN\nnew\\literal\nlast\nEND\nmiddle\nBEGIN\nEND\nafter\n", 0} =
             System.cmd(System.find_executable("bash"), [helper, "BEGIN", "END", body, target])

    File.write!(target, "not-BEGIN\nEND\nkeep\nBEGIN\nunterminated")

    assert {"not-BEGIN\nkeep\nBEGIN\nnew\\literal\nlast\nEND\n", 0} =
             System.cmd(System.find_executable("bash"), [helper, "BEGIN", "END", body, target])
  end
end
