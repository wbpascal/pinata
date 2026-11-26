defmodule Load.Player do
  @moduledoc """
  The script of one simulated player of the load run (`docs/technical/load-run.md`, "Script per player"): log in,
  create the character when the account has none, enter the map, run to a nearby point the block data allows every 1 to 2 s, a chat line
  every `chat_ms`, a heartbeat round trip every `ping_ms`. The process seeds itself with `Random.seed/1`, draws only
  through `Random` and reads time only through `Clock`.

  The runner gets exactly one outcome of the login phase: `{:load, :in_world, index, map, pos}`,
  `{:load, :prepared, index}`, `{:load, :connect_failed, index, part}` or `{:load, :failed, index, text}`; then
  `{:load, :rtt, ms}`, `{:load, :move}`, `{:load, :move_refused}`, `{:load, :chat}` and at most one
  `{:load, :disconnected, index}`.
  """

  alias GameData.BlockData

  alias Proto.Packets.{
    ActChatReq,
    ActMoverunCmd,
    AvatarCreateReq,
    CharClientBaseCmd,
    CharLoginAck,
    CharLoginReq,
    CharTutorialPopupAck,
    MapLoginAck,
    MapLogincompleteCmd,
    MapLoginReq,
    UserClientVersionCheckReq,
    UserLoginworldAck,
    UserLoginworldReq,
    UserUsLoginReq,
    UserWorldselectAck,
    UserWorldselectReq,
    UserXtrapReq
  }

  @key "20151116141627"
  @timeout 30_000

  @type config :: %{
          runner: pid(),
          index: pos_integer(),
          name: String.t(),
          password: String.t(),
          host: charlist(),
          port: :inet.port_number(),
          checksums: binary(),
          seed: integer(),
          mode: :play | :prepare,
          chat_ms: pos_integer(),
          ping_ms: pos_integer(),
          blocks: %{String.t() => BlockData.t()}
        }

  @doc "Plays the script of one player; returns when the player is prepared, failed or disconnected."
  @spec run(config()) :: :ok
  def run(config) do
    Random.seed(config.seed * 10_000 + config.index)

    outcome =
      try do
        login(config)
      rescue
        error -> {:failed, "crashed: " <> Exception.message(error)}
      end

    case outcome do
      :prepared ->
        report(config, {:load, :prepared, config.index})

      {:connect_failed, part} ->
        report(config, {:load, :connect_failed, config.index, part})

      {:failed, text} ->
        report(config, {:load, :failed, config.index, text})

      {:in_world, s} ->
        report(config, {:load, :rtt, s.rtt})
        report(config, {:load, :in_world, config.index, s.map, s.pos})
        if loop(start(config, s)) == :closed, do: report(config, {:load, :disconnected, config.index})
        :ok
    end
  end

  defp report(config, message) do
    send(config.runner, message)
    :ok
  end

  # -- login phase, in wire order

  defp login(c) do
    with {:ok, login} <- connect(c.host, c.port, :login),
         {:ok, login} <- put(login, %UserClientVersionCheckReq{version_key: @key}, "version check"),
         {:ok, _, login} <- await(login, "version check", exact(<<0x67, 0x0C, 1, 0>>)),
         {:ok, login} <-
           put(login, %UserUsLoginReq{user_name: c.name, password: c.password, spawnapps: <<0::160>>}, "login"),
         {:ok, login} <- put(login, %UserXtrapReq{key_length: 0, key: ""}, "login"),
         {:ok, _, login} <- await(login, "login", exact(<<0x05, 0x0C, 1>>)),
         {:ok, _, login} <- await(login, "login", &login_answer/1),
         {:ok, login} <- put(login, %UserWorldselectReq{world_no: 0}, "world select"),
         {:ok, {ip, wm_port, validate}, login} <- await(login, "world select", &world_select/1),
         :ok <- TestClient.close(login),
         {:ok, wm} <- connect(String.to_charlist(ip), wm_port, :world_manager),
         {:ok, wm} <- put(wm, %UserLoginworldReq{user_name: c.name, validate: validate}, "world login"),
         {:ok, {wm_handle, avatars}, wm} <- await(wm, "world login", &world_login/1),
         {:ok, {slot, char_name}, wm} <- character(wm, avatars, c.name) do
      if c.mode == :prepare do
        :ok = TestClient.close(wm)
        :prepared
      else
        enter(c, wm, wm_handle, slot, char_name)
      end
    end
  end

  defp enter(c, wm, wm_handle, slot, char_name) do
    with {:ok, wm} <- put(wm, %CharLoginReq{slot: slot}, "character login"),
         {:ok, {zone_ip, zone_port}, wm} <- char_login(wm),
         {:ok, zone} <- connect(String.to_charlist(zone_ip), zone_port, :zone),
         {:ok, zone} <-
           put(zone, %MapLoginReq{wm_handle: wm_handle, char_name: char_name, checksums: c.checksums}, "map login"),
         {:ok, {map, pos}, zone} <- map_login(zone, ""),
         {:ok, block} <- block(c, map),
         {:ok, zone} <- put(zone, %MapLogincompleteCmd{}, "map entry"),
         sent = now(),
         {:ok, zone} <- put(zone, <<0x04, 0x08>>, "map entry"),
         {:ok, _, zone} <- await(zone, "map entry", &pong/1) do
      {:in_world, %{zone: zone, wm: wm, map: map, pos: pos, block: block, rtt: now() - sent}}
    end
  end

  defp block(c, map) do
    case c.blocks do
      %{^map => block} -> {:ok, block}
      %{} -> {:failed, "map entry: no block data for map #{map} (not a plain field map)"}
    end
  end

  defp login_answer(<<0x0A, 0x0C, _::binary>>), do: {:ok, nil}
  defp login_answer(body), do: {:error, "refused: " <> describe(body)}

  defp world_select(body) do
    case Proto.decode(body) do
      # 6 to 10: open, by the player count (Login.WorldStatus)
      {:ok, %UserWorldselectAck{world_status: status, ip: ip, port: port, validate: validate}} when status in 6..10 ->
        {:ok, {ip, port, validate}}

      _other ->
        {:error, "unexpected " <> describe(body)}
    end
  end

  defp world_login(<<0x14, 0x0C, _::binary>> = body) do
    {:ok, %UserLoginworldAck{worldmanager: handle, avatars: avatars}} = Proto.decode(body)
    {:ok, {handle, avatars}}
  end

  defp world_login(body), do: {:error, "refused: " <> describe(body)}

  defp character(wm, [avatar | _], _name), do: {:ok, {avatar.slot, avatar.name}, wm}

  defp character(wm, [], name) do
    create = %AvatarCreateReq{
      slot: 0,
      name: name,
      gender: 0,
      chrclass: 1,
      race: 0,
      hairtype: 1,
      haircolor: 1,
      faceshape: 5
    }

    with {:ok, wm} <- put(wm, create, "character create"),
         {:ok, _, wm} <- await(wm, "character create", &created/1),
         do: {:ok, {0, name}, wm}
  end

  defp created(<<0x06, 0x14, _::binary>>), do: {:ok, nil}
  defp created(<<0x04, 0x14, code::little-16>>), do: {:error, "refused with code 0x#{hex(code, 4)}"}
  defp created(_body), do: :skip

  defp char_login(wm) do
    case await(wm, "character login", &char_login_answer/1) do
      {:ok, :tutorial, wm} ->
        with {:ok, wm} <- put(wm, %CharTutorialPopupAck{is_skip: 1}, "character login"), do: char_login(wm)

      other ->
        other
    end
  end

  defp char_login_answer(<<0x10, 0x11, _::binary>>), do: {:ok, :tutorial}

  defp char_login_answer(<<0x03, 0x10, _::binary>> = body) do
    {:ok, %CharLoginAck{zone_ip: ip, zone_port: port}} = Proto.decode(body)
    {:ok, {ip, port}}
  end

  defp char_login_answer(<<0x02, 0x10, code::little-16>>), do: {:error, "refused with code 0x#{hex(code, 4)}"}
  defp char_login_answer(_body), do: :skip

  defp map_login(zone, map) do
    case await(zone, "map login", &map_login_answer/1) do
      {:ok, {:map, map}, zone} -> map_login(zone, map)
      {:ok, {:at, pos}, zone} -> {:ok, {map, pos}, zone}
      failed -> failed
    end
  end

  defp map_login_answer(<<0x38, 0x10, _::binary>> = body) do
    {:ok, %CharClientBaseCmd{map: map}} = Proto.decode(body)
    {:ok, {:map, map}}
  end

  defp map_login_answer(<<0x02, 0x18, _::binary>> = body) do
    {:ok, %MapLoginAck{x: x, y: y}} = Proto.decode(body)
    {:ok, {:at, {x, y}}}
  end

  defp map_login_answer(<<0x04, 0x18, code::little-16, _::binary>>), do: {:error, "refused with code 0x#{hex(code, 4)}"}
  defp map_login_answer(_body), do: :skip

  defp pong(<<0x05, 0x08>>), do: {:ok, nil}
  defp pong(_body), do: :skip

  defp exact(expected) do
    fn
      ^expected -> {:ok, nil}
      body -> {:error, "unexpected " <> describe(body)}
    end
  end

  defp connect(host, port, part) do
    with {:ok, client} <- TestClient.try_connect(host, port),
         {:ok, <<0x07, 0x08, _::binary>>, client} <- TestClient.recv_raw(client, @timeout) do
      {:ok, client}
    else
      {:error, _reason} -> {:connect_failed, part}
      {:ok, body, _client} -> {:failed, "#{part} connect: unexpected " <> describe(body)}
    end
  end

  defp put(client, body, step) when is_binary(body), do: sent(TestClient.send_raw(client, body), step)
  defp put(client, packet, step), do: sent(TestClient.send_packet(client, packet), step)

  defp sent({:ok, client}, _step), do: {:ok, client}
  defp sent({:error, :closed}, step), do: {:failed, "#{step}: the connection closed"}

  # Reads bodies until `fun` accepts one (`{:ok, value}`) or refuses it (`{:error, text}`); answers heartbeats.
  defp await(client, step, fun) do
    case TestClient.recv_raw(client, @timeout) do
      {:ok, <<0x04, 0x08>>, client} ->
        with {:ok, client} <- put(client, <<0x05, 0x08>>, step), do: await(client, step, fun)

      {:ok, body, client} ->
        case fun.(body) do
          {:ok, value} -> {:ok, value, client}
          {:error, text} -> {:failed, "#{step} #{text}"}
          :skip -> await(client, step, fun)
        end

      {:error, :timeout} ->
        {:failed, "#{step}: no answer in #{div(@timeout, 1000)} s"}

      {:error, :closed} ->
        {:failed, "#{step}: the connection closed"}
    end
  end

  defp describe(<<lo, hi, payload::binary>>) do
    shown = binary_part(payload, 0, min(byte_size(payload), 16))
    "0x#{hex(hi * 256 + lo, 4)} #{Base.encode16(shown)}#{if byte_size(payload) > 16, do: "…"}"
  end

  defp describe(body), do: inspect(body)

  defp hex(n, digits), do: n |> Integer.to_string(16) |> String.pad_leading(digits, "0")

  defp now, do: Clock.monotonic_time(:millisecond)

  # -- play loop

  defp start(c, s) do
    now = now()

    Map.merge(s, %{
      c: c,
      next_move: now + 999 + Random.uniform(1001),
      next_chat: now + Random.uniform(c.chat_ms),
      next_ping: now + Random.uniform(c.ping_ms),
      ping_sent: nil
    })
  end

  defp loop(s) do
    now = now()
    next = Enum.min([s.next_move, s.next_chat, s.next_ping])

    if next <= now do
      with {:ok, s} <- due(s, now), {:ok, s} <- drain_wm(s), do: loop(s)
    else
      case TestClient.poll(s.zone, next - now) do
        {:ok, body, zone} -> s |> Map.put(:zone, zone) |> zone_body(body) |> then_loop()
        {:timeout, zone} -> loop(%{s | zone: zone})
        {:error, :closed} -> :closed
      end
    end
  end

  defp then_loop({:ok, s}), do: loop(s)
  defp then_loop(:closed), do: :closed

  defp zone_body(%{ping_sent: sent} = s, <<0x05, 0x08>>) when is_integer(sent) do
    report(s.c, {:load, :rtt, now() - sent})
    {:ok, %{s | ping_sent: nil}}
  end

  defp zone_body(s, <<0x04, 0x08>>), do: zone_send(s, <<0x05, 0x08>>)

  defp zone_body(s, <<0x1B, 0x20, x::little-32, y::little-32>>) do
    report(s.c, {:load, :move_refused})
    {:ok, %{s | pos: {x, y}}}
  end

  defp zone_body(s, <<0x4A, 0x20, x::little-32, y::little-32>>), do: {:ok, %{s | pos: {x, y}}}
  defp zone_body(s, _body), do: {:ok, s}

  defp zone_send(s, body) do
    case TestClient.send_raw(s.zone, body) do
      {:ok, zone} -> {:ok, %{s | zone: zone}}
      {:error, :closed} -> :closed
    end
  end

  defp due(s, now) do
    with {:ok, s} <- if(s.next_move <= now, do: move(s, now), else: {:ok, s}),
         {:ok, s} <- if(s.next_chat <= now, do: chat(s, now), else: {:ok, s}) do
      if s.next_ping <= now, do: ping(s, now), else: {:ok, s}
    end
  end

  defp move(%{pos: {px, py}} = s, now) do
    {tx, ty} = target(s.block, s.pos)

    with {:ok, s} <- zone_send(s, Proto.encode(%ActMoverunCmd{from_x: px, from_y: py, to_x: tx, to_y: ty})) do
      report(s.c, {:load, :move})
      {:ok, %{s | pos: {tx, ty}, next_move: now + 999 + Random.uniform(1001)}}
    end
  end

  @target_tries 20

  @doc """
  A run target near `pos` that the server accepts (`Zone.MapInstance`, `docs/technical/movement.md`): at most 90 units
  away in x and y, its cell not blocked and the straight line to it not blocked. After 20 draws without one the last
  draw is returned; the server then refuses it.
  """
  @spec target(BlockData.t(), {integer(), integer()}) :: {integer(), integer()}
  def target(block, pos), do: target(block, pos, @target_tries)

  defp target(block, {px, py} = pos, tries) do
    # at most 127 units: run speed 127 covers it within the shortest pause, so `from` stays near the server position
    to = {max(px + Random.uniform(181) - 91, 0), max(py + Random.uniform(181) - 91, 0)}
    {tx, ty} = to = if to == pos, do: {px + 1, py}, else: to

    if tries == 1 or (not BlockData.blocked?(block, tx, ty) and not BlockData.line_blocked?(block, pos, to)),
      do: to,
      else: target(block, pos, tries - 1)
  end

  defp chat(s, now) do
    line = %ActChatReq{item_link_count: 0, content: "load run " <> s.c.name, links: ""}

    with {:ok, s} <- zone_send(s, Proto.encode(line)) do
      report(s.c, {:load, :chat})
      {:ok, %{s | next_chat: now + s.c.chat_ms}}
    end
  end

  defp ping(s, now) do
    with {:ok, s} <- zone_send(s, <<0x04, 0x08>>), do: {:ok, %{s | ping_sent: now, next_ping: now + s.c.ping_ms}}
  end

  defp drain_wm(s) do
    case TestClient.poll(s.wm, 0) do
      {:ok, <<0x04, 0x08>>, wm} ->
        case TestClient.send_raw(wm, <<0x05, 0x08>>) do
          {:ok, wm} -> drain_wm(%{s | wm: wm})
          {:error, :closed} -> :closed
        end

      {:ok, _body, wm} ->
        drain_wm(%{s | wm: wm})

      {:timeout, wm} ->
        {:ok, %{s | wm: wm}}

      {:error, :closed} ->
        :closed
    end
  end
end
