defmodule Zone.ChatTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.ActSomeonechatCmd
  alias Proto.Packets.ActSomeoneshoutCmd

  @penalties [{10_000, 15_000}, {20_000, 30_000}, {30_000, 45_000}, {60_000, 90_000}]
  @rules %{
    chat?: true,
    shout?: true,
    shout: %{level: 5, delay_s: 2},
    spam: %{repeat: 3, window_ms: 3000, penalties: @penalties}
  }
  @empty %{ring: [], block_until: :none, probation_until: :none, next_shout: :none}

  defp lines(state, times, rules \\ @rules, kind \\ :normal, level \\ 1) do
    Enum.map_reduce(times, state, fn now, state -> Zone.Chat.check(kind, state, level, rules, now) end)
  end

  # three lines at once from `state` at `now`: the verdict of the third
  defp offend(state, now, rules \\ @rules) do
    {[:pass, :pass, verdict], state} = lines(state, [now, now, now], rules)
    {verdict, state}
  end

  test "normal chat passes; a map without chat is silent" do
    assert {:pass, %{ring: [-5]}} = Zone.Chat.check(:normal, @empty, 1, @rules, -5)
    assert {:silent, @empty} = Zone.Chat.check(:normal, @empty, 1, %{@rules | chat?: false}, -5)
  end

  test "shout: map flag, data, level and delay" do
    assert {:silent, @empty} = Zone.Chat.check(:shout, @empty, 6, %{@rules | shout?: false}, 0)
    assert {:silent, @empty} = Zone.Chat.check(:shout, @empty, 6, %{@rules | shout: :off}, 0)
    assert {:silent, @empty} = Zone.Chat.check(:shout, @empty, 5, @rules, 0)

    now = -10_000
    assert {:pass, state} = Zone.Chat.check(:shout, @empty, 6, @rules, now)
    assert state.next_shout == now + 2000
    assert {:silent, ^state} = Zone.Chat.check(:shout, state, 6, @rules, now + 2000)
    assert {:pass, _state} = Zone.Chat.check(:shout, state, 6, @rules, now + 2001)
  end

  test "the shout delay starts before the spam check" do
    t = 500
    {[:pass, :pass], state} = lines(@empty, [t, t])
    assert {{:blocked, 10}, state} = Zone.Chat.check(:shout, state, 6, @rules, t)
    assert state.next_shout == t + 2000
  end

  test "spam window" do
    assert {[:pass, :pass, {:blocked, 10}], state} = lines(@empty, [0, 1000, 3000])
    assert %{ring: [], block_until: 13_000, probation_until: 28_000} = state

    assert {[:pass, :pass, :pass, {:blocked, 10}], _state} = lines(@empty, [0, 1000, 3001, 3500])
  end

  test "while blocked" do
    {{:blocked, 10}, state} = offend(@empty, 0)
    assert {{:blocked, 5}, ^state} = Zone.Chat.check(:normal, state, 1, @rules, 5000)
    assert {{:blocked, 1}, ^state} = Zone.Chat.check(:normal, state, 1, @rules, 9500)
    assert {:pass, _state} = Zone.Chat.check(:normal, state, 1, @rules, 10_000)
  end

  test "a repeat offender climbs inside probation and is capped at the last row" do
    {{:blocked, 10}, state} = offend(@empty, -100_000)
    {{:blocked, 20}, state} = offend(state, state.block_until)
    {{:blocked, 30}, state} = offend(state, state.block_until)
    {{:blocked, 60}, state} = offend(state, state.block_until)
    {{:blocked, 60}, state} = offend(state, state.block_until)
    assert {{:blocked, 10}, _state} = offend(state, state.probation_until)
  end

  test "the cap with two penalty rows" do
    rules = put_in(@rules.spam.penalties, [{10_000, 15_000}, {20_000, 30_000}])
    {{:blocked, 10}, state} = offend(@empty, 0, rules)
    {{:blocked, 20}, state} = offend(state, state.block_until, rules)
    assert {{:blocked, 20}, _state} = offend(state, state.block_until, rules)
  end

  test "no spam filter" do
    assert {verdicts, _state} = lines(@empty, List.duplicate(0, 10), %{@rules | spam: :off})
    assert verdicts == List.duplicate(:pass, 10)
  end

  test "rules from the 2016 data" do
    penalties =
      for {b, p} <-
            [{10, 15}, {20, 30}, {30, 45}, {60, 90}, {120, 180}, {240, 360}, {480, 720}, {960, 1440}] ++
              [{1920, 2880}, {3600, 5400}],
          do: {b * 1000, p * 1000}

    assert Zone.Chat.rules("RouN") == put_in(@rules.spam.penalties, penalties)
    assert %{shout?: false, chat?: true} = Zone.Chat.rules("EldPri")
    assert %{shout?: false, chat?: false} = Zone.Chat.rules("NoSuchMap")
  end

  test "packets" do
    player = %{stub("X45A") | handle: 8000}
    line = %{item_link_count: 1, content: "hi", links: :binary.copy(<<0xAB>>, 0x67)}

    assert %ActSomeonechatCmd{
             item_link_count: 1,
             handle: 8000,
             len: 2,
             flag: 0x02,
             font_color: 0,
             balloon_color: 0,
             content: "hi",
             links: <<0xAB, _::binary>>
           } = Zone.Chat.packet(:normal, player, line)

    assert %ActSomeoneshoutCmd{item_link_count: 1, speaker: "X45A", flag: 0, content: "hi"} =
             Zone.Chat.packet(:shout, player, line)
  end

  defp stub(name) do
    character = %{
      id: 1,
      slot: 0,
      name: name,
      level: 1,
      exp: 0,
      login_map: "RouN",
      login_x: 6477,
      login_y: 9844,
      hp: 1,
      sp: 1,
      money: 0,
      hp_stones: 0,
      sp_stones: 0,
      race: 0,
      class: 1,
      gender: 0,
      hair: 0,
      hair_color: 0,
      face: 0,
      admin_level: 0,
      equipment: []
    }

    %Zone.Player{
      character: character,
      world_no: 0,
      map: "RouN",
      x: 6477,
      y: 9844,
      walk_speed: 33,
      run_speed: 127,
      map_type: 0,
      equipment: [],
      address: "127.0.0.1",
      last_good: {6477, 9844},
      conn: :none
    }
  end
end
