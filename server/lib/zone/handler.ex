defmodule Zone.Handler do
  @moduledoc """
  Packet handler of the Zone part: the map login `0x1801` (flow: `docs/technical/flows/enter-world.md`) and the map
  entry up to `0x1803` (flow: `docs/technical/flows/map-entry.md`).

  First the Client data check: the 49 checksums of the packet against `GameData.client_checksums/0`. The first
  difference answers `0x1804 {0x147, index}` and closes the connection; the reservation stays. Then one call to the
  WorldManager session with the handle (`Cluster.Sessions.redeem/2`) redeems the map-login ticket. A refusal answers
  `0x1804` with the code of the original WorldManager (Z01-B1 fixed) and closes the connection. From an accepted
  map login on the connection monitors the session and closes when it ends.

  An accepted map login loads the character (`Persistence.load_character/3`), builds its `Zone.Player`, enters it
  into the map instance (mode 0) and sends the burst of `Zone.MapEntry.login/1`. Any failure there answers
  `0x1804 {0x142, 0xFF}` and closes with one `warning` line. On `0x1803` the player becomes visible (mode 1), the
  Zone sends the burst of `Zone.MapEntry.login_complete/1` and the WorldManager session sends its own
  (`Cluster.Sessions.map_login_done/1`). `0x200B` is accepted without an answer; `0x302C` and `0x3020` get the
  empty answers of `Zone.MapEntry.Placeholders`.
  """

  @behaviour Net.Handler

  alias Proto.Packets.ActEndoftradeCmd
  alias Proto.Packets.ItemChargedinvenopenReq
  alias Proto.Packets.ItemRewardinvenopenReq
  alias Proto.Packets.MapLogincompleteCmd
  alias Proto.Packets.MapLoginfailAck
  alias Proto.Packets.MapLoginReq
  alias Zone.MapEntry.Placeholders

  @enforce_keys [:checksums]
  defstruct [:checksums, step: :login, session: :none, entry: :none, map: :none, player: :none]

  @type t :: %__MODULE__{
          checksums: [GameData.ClientData.checksum()],
          step: :login | :loading | :in_world,
          session: :none | pid(),
          entry: :none | Cluster.Sessions.entry(),
          map: :none | pid(),
          player: :none | Zone.Player.t()
        }

  @type entry_failure :: :not_found | :database | :no_map | :game_data | :no_block_data | :full

  @impl Net.Handler
  def init(_settings), do: %__MODULE__{checksums: GameData.client_checksums()}

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :login} = state, %MapLoginReq{wm_handle: h, char_name: name, checksums: theirs}) do
    case GameData.ClientData.first_difference(state.checksums, theirs) do
      {index, table, ours, client} ->
        {state,
         [
           {:send, %MapLoginfailAck{error: 0x147, wrong_data_file_index: index}},
           {:close, :warning,
            "Client data check failed: character #{inspect(name)}, table #{table}, server #{ours}, client #{inspect(client)}"}
         ]}

      :none ->
        {state, [{:perform, {:redeem, h, name}}]}
    end
  end

  def handle_packet(%__MODULE__{step: :loading, player: %Zone.Player{} = p} = state, %MapLogincompleteCmd{}),
    do: {state, [{:perform, {:login_complete, state.map, p.handle, state.session}}]}

  # Accepted without an answer, as the original after a map login (issue 88).
  def handle_packet(%__MODULE__{step: step} = state, %ActEndoftradeCmd{}) when step in [:loading, :in_world],
    do: {state, []}

  def handle_packet(%__MODULE__{step: step} = state, %ItemRewardinvenopenReq{}) when step in [:loading, :in_world],
    do: {state, [{:send, Placeholders.reward_inventory()}]}

  def handle_packet(%__MODULE__{step: step} = state, %ItemChargedinvenopenReq{}) when step in [:loading, :in_world],
    do: {state, [{:send, Placeholders.charged_inventory()}]}

  def handle_packet(state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:redeemed, {:ok, pid, entry}}),
    do:
      {%{state | session: pid, entry: entry},
       [
         {:log, :info, "map login accepted: character #{entry.character_id}, map #{entry.map}"},
         {:perform, {:enter, entry}}
       ]}

  # Z01-B1 fixed: the refusal carries the real code.
  def handle_info(state, {:redeemed, {:error, reason}}),
    do:
      {state,
       [
         {:send, %MapLoginfailAck{error: code(reason), wrong_data_file_index: 0xFF}},
         {:close, :info, "map login refused: " <> text(reason)}
       ]}

  def handle_info(state, {:entered, {:ok, map, player}}),
    do: {%{state | step: :loading, map: map, player: player}, for(p <- Zone.MapEntry.login(player), do: {:send, p})}

  # 0x142: the original's code when the player cannot be placed on the map.
  def handle_info(state, {:entered, {:error, reason}}),
    do:
      {state,
       [
         {:send, %MapLoginfailAck{error: 0x142, wrong_data_file_index: 0xFF}},
         {:close, :warning, "map entry failed: " <> entry_text(reason)}
       ]}

  def handle_info(state, {:login_completed, {:ok, packets}}),
    do: {%{state | step: :in_world}, for(p <- packets, do: {:send, p})}

  def handle_info(state, {:login_completed, {:error, :not_entered}}),
    do: {state, [{:close, :warning, "map login complete failed: not on the map"}]}

  def handle_info(%__MODULE__{session: pid} = state, {:down, pid}), do: {state, [{:close, :info, "session ended"}]}
  def handle_info(state, {:down, _other}), do: {state, []}

  @impl Net.Handler
  def perform({:redeem, h, name}) do
    result = Cluster.Sessions.redeem(h, name)
    _ = with {:ok, pid, _entry} <- result, do: Process.monitor(pid)
    {:redeemed, result}
  end

  def perform({:enter, entry}) do
    result =
      with {:ok, character} <- Persistence.load_character(entry.world_no, entry.user_no, entry.character_id),
           {:ok, map} <- whereis(entry),
           {:ok, player} <- Zone.Player.new(character, entry, address(), self()),
           {:ok, handle} <- Zone.MapInstance.enter(map, player) do
        {:ok, map, %{player | handle: handle}}
      end

    {:entered, result}
  end

  def perform({:login_complete, map, handle, session}) do
    result = Zone.MapInstance.login_complete(map, handle)
    _ = with {:ok, _packets} <- result, do: Cluster.Sessions.map_login_done(session)
    {:login_completed, result}
  end

  defp whereis(entry) do
    case Zone.MapInstance.whereis(entry.world_no, entry.map) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :no_map}
    end
  end

  # The peer metadata set by Net.Connection: "address:port".
  defp address do
    case Logger.metadata()[:peer] do
      peer when is_binary(peer) -> peer |> String.split(":") |> Enum.drop(-1) |> Enum.join(":")
      _none -> ""
    end
  end

  defp code(:no_session), do: 0x141
  defp code(:no_ticket), do: 0x141
  defp code(:wrong_node), do: 0x141
  defp code(:wrong_character), do: 0x590

  defp text(:no_session), do: "no session for the handle"
  defp text(:no_ticket), do: "no map-login ticket"
  defp text(:wrong_node), do: "reserved for another Zone node"
  defp text(:wrong_character), do: "not the reserved character"

  defp entry_text(:not_found), do: "character not found"
  defp entry_text(:database), do: "database failure"
  defp entry_text(:no_map), do: "no map instance"
  defp entry_text(:game_data), do: "a game data row is missing"
  defp entry_text(:no_block_data), do: "block data unreadable"
  defp entry_text(:full), do: "map instance full"
end
