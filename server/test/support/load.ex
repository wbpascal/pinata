defmodule Load do
  @moduledoc """
  The load run (`docs/technical/load-run.md`): many `Load.Player` processes against a running server. `main/1` is the
  entry of `MIX_ENV=test mix pinata.load` (alias in `mix.exs`, script `test/support/load.exs`); `run/1` is the same
  run without the exit, used by `test/load_test.exs`.

  It reports only what is visible from outside (connect failures, failed logins, disconnects, round-trip time); the
  capacity figures are read on the server with `Pinata.Figures`.
  """

  @switches [
    host: :string,
    port: :integer,
    scenario: :string,
    players: :integer,
    prefix: :string,
    password: :string,
    seed: :integer,
    hold: :integer,
    stop_after_hold: :boolean,
    prepare: :string,
    data_dir: :string,
    map: :string
  ]

  @usage """
  usage: MIX_ENV=test mix pinata.load --scenario world|crowd --players <1 to 9999> [options]
    --host <address>      Login address (127.0.0.1)
    --port <port>         Login port (9010)
    --prefix <prefix>     account names <prefix>0001 ... (load)
    --password <text>     the password of every account (load)
    --seed <n>            seed of the scripts and of the placement (1)
    --hold <seconds>      the hold window (300)
    --stop-after-hold     stop after the hold; exit 0 only when every player entered and nothing failed
    --prepare <file>      log every player in, create missing characters, write the placement list to <file>
    --data-dir <dir>      data directory: block data of the move targets, placement of --prepare (data)
    --map <map>           the map of the Crowd scenario (Rou)
  See docs/technical/load-run.md.
  """

  @ramp_ms 20
  @report_ms 60_000

  @type options :: %{
          host: charlist(),
          port: :inet.port_number(),
          scenario: :world | :crowd,
          players: pos_integer(),
          prefix: String.t(),
          password: String.t(),
          seed: integer(),
          hold_ms: non_neg_integer(),
          stop_after_hold: boolean(),
          prepare: :none | Path.t(),
          data_dir: Path.t(),
          map: String.t(),
          chat_ms: pos_integer(),
          ping_ms: pos_integer()
        }

  @type result :: %{
          players: pos_integer(),
          in_world: non_neg_integer(),
          prepared: non_neg_integer(),
          connect_failures: non_neg_integer(),
          failures: [String.t()],
          disconnects: non_neg_integer(),
          crashes: non_neg_integer(),
          rtt: [non_neg_integer()],
          moves: non_neg_integer(),
          moves_refused: non_neg_integer(),
          chats: non_neg_integer(),
          maps: %{String.t() => pos_integer()},
          entered: %{pos_integer() => {String.t(), integer(), integer()}}
        }

  @doc "Parses the command line of the task."
  @spec parse([String.t()]) :: {:ok, options()} | {:error, String.t()}
  def parse(argv) do
    with {o, [], []} <- OptionParser.parse(argv, strict: @switches),
         {:ok, scenario} <- scenario(o[:scenario]),
         players when is_integer(players) and players in 1..9999 <- o[:players],
         hold when is_integer(hold) and hold >= 0 <- Keyword.get(o, :hold, 300),
         port when port in 1..65_535 <- Keyword.get(o, :port, 9010) do
      {:ok,
       %{
         host: o |> Keyword.get(:host, "127.0.0.1") |> String.to_charlist(),
         port: port,
         scenario: scenario,
         players: players,
         prefix: Keyword.get(o, :prefix, "load"),
         password: Keyword.get(o, :password, "load"),
         seed: Keyword.get(o, :seed, 1),
         hold_ms: hold * 1000,
         stop_after_hold: Keyword.get(o, :stop_after_hold, false),
         prepare: Keyword.get(o, :prepare, :none),
         data_dir: Keyword.get(o, :data_dir, "data"),
         map: Keyword.get(o, :map, "Rou"),
         chat_ms: 30_000,
         ping_ms: 10_000
       }}
    else
      _invalid -> {:error, @usage}
    end
  end

  defp scenario("world"), do: {:ok, :world}
  defp scenario("crowd"), do: {:ok, :crowd}
  defp scenario(_other), do: :error

  @doc "The task: parses, runs and exits (status 2 on a bad command line, 1 when the run is not `ok?/1`)."
  @spec main([String.t()]) :: :ok
  def main(argv) do
    case parse(argv) do
      {:error, usage} ->
        IO.puts(:stderr, usage)
        System.halt(2)

      {:ok, options} ->
        result = run(options)
        System.halt(if ok?(result), do: 0, else: 1)
    end
  end

  @doc "True when every player was prepared or entered the world and nothing failed, disconnected or crashed."
  @spec ok?(result()) :: boolean()
  def ok?(r) do
    r.in_world + r.prepared == r.players and r.connect_failures == 0 and r.failures == [] and r.disconnects == 0 and
      r.crashes == 0
  end

  @doc """
  Runs the load: ramp at 50 logins per second, then (play mode) the hold window. Returns after `--prepare` or with
  `stop_after_hold`; otherwise it plays on and prints the report every 60 s until the task is ended.
  """
  @spec run(options()) :: result()
  def run(o) do
    IO.puts("load run: #{o.scenario}, #{o.players} players, #{o.host}:#{o.port}, seed #{o.seed}")
    names = for i <- 1..o.players, do: o.prefix <> String.pad_leading(Integer.to_string(i), 4, "0")

    # the data directory first, so that a bad one fails before any login
    maps = Load.Placement.maps(o.data_dir)

    lines =
      if o.prepare != :none do
        Random.seed(o.seed)
        Load.Placement.list(o.scenario, names, o.data_dir, o.map, maps)
      end

    # the players check their move targets against the block data; prepared players never move
    blocks = if o.prepare == :none, do: Load.Placement.blocks(o.data_dir, maps), else: %{}

    state = %{result: result(o.players), alive: %{}, pending: MapSet.new(1..o.players)}
    state = ramp(o, names, blocks, state)
    state = await_outcomes(state)

    if o.prepare != :none do
      # the prepared players end by themselves
      state = stopped(state)
      File.write!(o.prepare, Enum.map(lines, &[&1, "\n"]))
      IO.puts("prepared #{state.result.prepared} of #{o.players} players, placement written to #{o.prepare}")
      IO.puts("place them (the characters must not be in the world):")
      IO.puts("  from source: mix pinata.character.place < #{o.prepare}")
      IO.puts("  release:     bin/pinata eval \"Persistence.Release.place_characters()\" < #{o.prepare}")
      report_failures(state.result)
      state.result
    else
      hold(o, state)
    end
  end

  defp result(players) do
    %{
      players: players,
      in_world: 0,
      prepared: 0,
      connect_failures: 0,
      failures: [],
      disconnects: 0,
      crashes: 0,
      rtt: [],
      moves: 0,
      moves_refused: 0,
      chats: 0,
      maps: %{},
      entered: %{}
    }
  end

  defp ramp(o, names, blocks, state) do
    checksums = checksums()
    password = Base.encode16(:crypto.hash(:md5, o.password), case: :lower)
    runner = self()

    names
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {name, index}, state ->
      config = %{
        runner: runner,
        index: index,
        name: name,
        password: password,
        host: o.host,
        port: o.port,
        checksums: checksums,
        seed: o.seed,
        mode: if(o.prepare == :none, do: :play, else: :prepare),
        chat_ms: o.chat_ms,
        ping_ms: o.ping_ms,
        blocks: blocks
      }

      {pid, ref} = spawn_monitor(fn -> Load.Player.run(config) end)
      Process.sleep(@ramp_ms)
      put_in(state.alive[ref], {pid, index})
    end)
  end

  # the 49 checksums of the Client data check of a 2016 client
  defp checksums do
    transcript = "../replay/transcripts/26_11_15_idle_in_world.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    %{payload: payload} = Enum.find(transcript.packets, &(&1.opcode == 0x1801 and &1.dir == :client))
    binary_part(payload, 22, 1568)
  end

  defp await_outcomes(state) do
    if MapSet.size(state.pending) == 0 do
      state
    else
      receive do
        message -> state |> handle(message) |> await_outcomes()
      end
    end
  end

  defp hold(o, state) do
    r = state.result
    top = r.maps |> Enum.sort_by(fn {map, n} -> {-n, map} end) |> Enum.take(5)
    shown = Enum.map_join(top, ", ", fn {map, n} -> "#{map} #{n}" end)
    IO.puts("in the world: #{r.in_world} of #{o.players} on #{map_size(r.maps)} maps (#{shown})")

    if o.scenario == :crowd and map_size(r.maps) > 1,
      do: IO.puts("the players stand on #{map_size(r.maps)} maps: was the placement applied?")

    IO.puts("hold started")
    state = collect(state, o.hold_ms)
    IO.puts("hold complete")
    report(state.result)

    if o.stop_after_hold do
      Enum.each(state.alive, fn {_ref, {pid, _index}} -> Process.exit(pid, :shutdown) end)
      stopped(state).result
    else
      play_on(state)
    end
  end

  defp play_on(state) do
    state = collect(state, @report_ms)
    report(state.result)
    play_on(state)
  end

  defp stopped(state) do
    if map_size(state.alive) == 0 do
      state
    else
      receive do
        message -> state |> handle(message) |> stopped()
      end
    end
  end

  defp collect(state, ms), do: collect_until(state, Clock.monotonic_time(:millisecond) + ms)

  defp collect_until(state, deadline) do
    wait = max(deadline - Clock.monotonic_time(:millisecond), 0)

    receive do
      message -> state |> handle(message) |> collect_until(deadline)
    after
      wait -> state
    end
  end

  defp handle(state, {:load, :in_world, index, map, {x, y}}) do
    state
    |> outcome(index)
    |> update(:in_world, &(&1 + 1))
    |> update(:maps, &Map.update(&1, map, 1, fn n -> n + 1 end))
    |> update(:entered, &Map.put(&1, index, {map, x, y}))
  end

  defp handle(state, {:load, :prepared, index}), do: state |> outcome(index) |> update(:prepared, &(&1 + 1))

  defp handle(state, {:load, :connect_failed, index, _part}),
    do: state |> outcome(index) |> update(:connect_failures, &(&1 + 1))

  defp handle(state, {:load, :failed, index, text}), do: state |> outcome(index) |> update(:failures, &(&1 ++ [text]))
  defp handle(state, {:load, :rtt, ms}), do: update(state, :rtt, &[ms | &1])
  defp handle(state, {:load, :move}), do: update(state, :moves, &(&1 + 1))
  defp handle(state, {:load, :move_refused}), do: update(state, :moves_refused, &(&1 + 1))
  defp handle(state, {:load, :chat}), do: update(state, :chats, &(&1 + 1))
  defp handle(state, {:load, :disconnected, _index}), do: update(state, :disconnects, &(&1 + 1))

  defp handle(state, {:DOWN, ref, :process, _pid, reason}) do
    {{_pid, index}, alive} = Map.pop!(state.alive, ref)
    state = %{state | alive: alive}

    cond do
      # died before its outcome: a crash of the script
      MapSet.member?(state.pending, index) -> state |> outcome(index) |> update(:crashes, &(&1 + 1))
      reason in [:normal, :shutdown] -> state
      true -> update(state, :crashes, &(&1 + 1))
    end
  end

  defp outcome(state, index), do: %{state | pending: MapSet.delete(state.pending, index)}
  defp update(state, key, fun), do: %{state | result: Map.update!(state.result, key, fun)}

  defp report(r) do
    IO.puts("connect failures: #{r.connect_failures}")
    report_failures(r)
    IO.puts("disconnects: #{r.disconnects}")
    IO.puts("crashes: #{r.crashes}")

    case Enum.sort(r.rtt) do
      [] ->
        IO.puts("round-trip time: no samples")

      sorted ->
        median = Enum.at(sorted, div(length(sorted), 2))

        IO.puts(
          "round-trip time: #{length(sorted)} samples, min #{hd(sorted)} ms, median #{median} ms, max #{List.last(sorted)} ms"
        )
    end

    IO.puts("moves sent: #{r.moves}, refused: #{r.moves_refused}")
    IO.puts("chat lines sent: #{r.chats}")
  end

  defp report_failures(r) do
    IO.puts("failed logins: #{length(r.failures)}")
    Enum.each(Enum.take(r.failures, 5), &IO.puts("  " <> &1))
  end
end
