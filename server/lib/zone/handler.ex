defmodule Zone.Handler do
  @moduledoc """
  Packet handler of the Zone part: the map login `0x1801` (flow: `docs/technical/flows/enter-world.md`).

  First the Client data check: the 49 checksums of the packet against `GameData.client_checksums/0`. The first
  difference answers `0x1804 {0x147, index}` and closes the connection; the reservation stays. Then one call to the
  WorldManager session with the handle (`Cluster.Sessions.redeem/2`) redeems the map-login ticket. A refusal answers
  `0x1804` with the code of the original WorldManager (Z01-B1 fixed) and closes the connection. An accepted map login
  sends nothing yet (the map-entry burst is issue 108); from then on the connection monitors the session and closes
  when it ends.
  """

  @behaviour Net.Handler

  alias Proto.Packets.MapLoginfailAck
  alias Proto.Packets.MapLoginReq

  @enforce_keys [:checksums]
  defstruct [:checksums, step: :login, session: :none, entry: :none]

  @type t :: %__MODULE__{
          checksums: [GameData.ClientData.checksum()],
          step: :login | :entering,
          session: :none | pid(),
          entry: :none | Cluster.Sessions.entry()
        }

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

  def handle_packet(state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:redeemed, {:ok, pid, entry}}),
    do:
      {%{state | step: :entering, session: pid, entry: entry},
       [{:log, :info, "map login accepted: character #{entry.character_id}, map #{entry.map}"}]}

  # Z01-B1 fixed: the refusal carries the real code.
  def handle_info(state, {:redeemed, {:error, reason}}),
    do:
      {state,
       [
         {:send, %MapLoginfailAck{error: code(reason), wrong_data_file_index: 0xFF}},
         {:close, :info, "map login refused: " <> text(reason)}
       ]}

  def handle_info(%__MODULE__{session: pid} = state, {:down, pid}), do: {state, [{:close, :info, "session ended"}]}
  def handle_info(state, {:down, _other}), do: {state, []}

  @impl Net.Handler
  def perform({:redeem, h, name}) do
    result = Cluster.Sessions.redeem(h, name)
    _ = with {:ok, pid, _entry} <- result, do: Process.monitor(pid)
    {:redeemed, result}
  end

  defp code(:no_session), do: 0x141
  defp code(:no_ticket), do: 0x141
  defp code(:wrong_node), do: 0x141
  defp code(:wrong_character), do: 0x590

  defp text(:no_session), do: "no session for the handle"
  defp text(:no_ticket), do: "no map-login ticket"
  defp text(:wrong_node), do: "reserved for another Zone node"
  defp text(:wrong_character), do: "not the reserved character"
end
