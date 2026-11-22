defmodule Zone.Chat do
  @moduledoc """
  The rules of normal chat and shout and the chat spam filter (`docs/pseudocode/zone/Z02-actions.md` §3,
  `sp_SpamCheck` @ FUN_005649d0, `sp_SpamSetBlock` @ FUN_00562ab0, `sp_SpamSendBlockTimeToClient` @ FUN_005607a0).
  Pure: the map instance holds the rules (`rules/1`) and each player's `state` (`Zone.Player`, field `chat`) and
  passes the time. Times are milliseconds of `Clock.monotonic_time/1`; `:none` is an unset time.

  Spam filter: the times of the last `repeat` counted lines are kept. When `repeat` lines fall within `window_ms`, the
  chat of the player is blocked for the block time of its penalty level, then stays on probation for the probation
  time. A repeat offence inside the probation time climbs a level (10 s, 20 s, 30 s, 60 s with the 2016 data), capped
  at the last row of `SpamerPenalty`. A line while blocked is answered with the seconds left.
  """

  alias Proto.Packets.ActSomeonechatCmd
  alias Proto.Packets.ActSomeoneshoutCmd

  @type state :: %{
          ring: [integer()],
          block_until: :none | integer(),
          probation_until: :none | integer(),
          next_shout: :none | integer()
        }
  @type spam ::
          :off
          | %{
              repeat: pos_integer(),
              window_ms: non_neg_integer(),
              penalties: [{block_ms :: non_neg_integer(), probate_ms :: non_neg_integer()}, ...]
            }
  @type shout :: :off | %{level: integer(), delay_s: non_neg_integer()}
  @type rules :: %{chat?: boolean(), shout?: boolean(), shout: shout(), spam: spam()}
  @type line :: %{item_link_count: non_neg_integer(), content: binary(), links: binary()}
  @type verdict :: :pass | :silent | {:blocked, seconds :: non_neg_integer()}

  @doc """
  The limits shared by every map: the shout level and delay (`ShoutLevel`, `ShoutDelay` of `ChrCommon`; `:off` when
  one is missing) and the spam filter (`SpamerPenaltyRule`, `SpamerPenalty`; `:off` without a usable row).
  """
  @spec common() :: %{shout: shout(), spam: spam()}
  def common, do: %{shout: shout(), spam: spam()}

  defp shout do
    with {:ok, %{argument: level}} <- GameData.fetch(GameData.ChrCommon, "ShoutLevel"),
         {:ok, %{argument: delay}} <- GameData.fetch(GameData.ChrCommon, "ShoutDelay"),
         true <- delay >= 0 do
      %{level: level, delay_s: delay}
    else
      _missing -> :off
    end
  end

  defp spam do
    with [%{repeat_rule: repeat, second_rule: window} | _] when repeat >= 1 and window >= 0 <-
           GameData.all(GameData.SpamerPenaltyRule),
         [_ | _] = rows <- GameData.all(GameData.SpamerPenalty),
         true <- Enum.all?(rows, &(&1.chat_block_time >= 0 and &1.probate_time >= 0)) do
      %{
        repeat: repeat,
        window_ms: window,
        penalties: for(row <- rows, do: {row.chat_block_time * 1000, row.probate_time * 1000})
      }
    else
      _unusable -> :off
    end
  end

  @doc "The rules of a map: `common/0` and the `Chat` / `Shout` flags of its first `FieldList` row (both false without a row)."
  @spec rules(String.t()) :: rules()
  def rules(map_name) do
    {chat?, shout?} =
      case GameData.lookup(GameData.FieldList, :map_id_client, map_name) do
        [row | _] -> {row.chat != 0, row.shout != 0}
        [] -> {false, false}
      end

    Map.merge(common(), %{chat?: chat?, shout?: shout?})
  end

  @doc """
  Whether a line of the player passes at `now`, and the player's new state. A refusal by the map flag, the level or
  the shout delay is `:silent`; the spam filter answers `{:blocked, seconds}`. An accepted shout attempt starts the
  delay before the spam check, so a shout the filter blocks still starts it.
  """
  @spec check(:normal | :shout, state(), integer(), rules(), integer()) :: {verdict(), state()}
  def check(:normal, state, _level, %{chat?: false}, _now), do: {:silent, state}
  def check(:normal, state, _level, rules, now), do: spam(state, rules.spam, now)

  def check(:shout, state, level, rules, now) do
    cond do
      not rules.shout? or rules.shout == :off -> {:silent, state}
      level <= rules.shout.level -> {:silent, state}
      # the original needs nextShout < now
      is_integer(state.next_shout) and now <= state.next_shout -> {:silent, state}
      true -> spam(%{state | next_shout: now + rules.shout.delay_s * 1000}, rules.spam, now)
    end
  end

  @doc "The packet of a passed line of the player."
  @spec packet(:normal | :shout, Zone.Player.t(), line()) :: ActSomeonechatCmd.t() | ActSomeoneshoutCmd.t()
  def packet(:normal, %Zone.Player{} = player, line) do
    %ActSomeonechatCmd{
      item_link_count: line.item_link_count,
      handle: player.handle,
      len: byte_size(line.content),
      # bit 1: the chat window; bit 0 (GM colour) is milestone 7
      flag: 0x02,
      font_color: 0,
      balloon_color: 0,
      content: line.content,
      links: line.links
    }
  end

  def packet(:shout, %Zone.Player{} = player, line) do
    %ActSomeoneshoutCmd{
      item_link_count: line.item_link_count,
      speaker: player.character.name,
      flag: 0,
      content: line.content,
      links: line.links
    }
  end

  defp spam(state, :off, _now), do: {:pass, state}

  defp spam(%{block_until: until} = state, _spam, now) when is_integer(until) and now < until,
    do: {{:blocked, seconds(until - now)}, state}

  defp spam(state, spam, now) do
    ring = Enum.take([now | state.ring], spam.repeat)

    if length(ring) == spam.repeat and now - List.last(ring) <= spam.window_ms,
      do: penalize(state, spam.penalties, now),
      else: {:pass, %{state | ring: ring}}
  end

  defp penalize(state, penalties, now) do
    {level, sum} = level(state, penalties, now)
    {block_ms, probate_ms} = Enum.at(penalties, level - 1)
    block_until = now + block_ms
    state = %{state | ring: [], block_until: block_until, probation_until: block_until + probate_ms + sum}
    {{:blocked, seconds(block_ms)}, state}
  end

  # only called with left_ms > 0, or 0 for a row with block time 0
  defp seconds(left_ms) when left_ms < 1000, do: 1
  defp seconds(left_ms), do: div(left_ms, 1000)

  # A repeat offender inside the probation time climbs: the first level whose summed probation times of the levels
  # below it cover the last probation.
  defp level(%{probation_until: p, block_until: b}, penalties, now) when is_integer(p) and is_integer(b) and now < p do
    max = length(penalties)

    penalties
    |> Enum.take(max - 1)
    |> Enum.with_index(1)
    |> Enum.reduce_while({max, 0}, fn {{_block, probate}, l}, {_level, sum} ->
      sum = sum + probate
      if p - b <= sum, do: {:halt, {l + 1, sum}}, else: {:cont, {max, sum}}
    end)
  end

  defp level(_state, _penalties, _now), do: {1, 0}
end
