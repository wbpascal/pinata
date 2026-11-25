# One player enters the map "Rou" of world 0, so that the map instance ticks. The CI job otel-smoke runs this in the
# release with `bin/pinata rpc "Code.eval_file(...)"`; test/workflow_test.exs loads it, so that a change to
# Zone.Player or Zone.MapInstance.enter/2 fails `mix check` (server/AGENTS.md, "CI jobs").
{:ok, map} = Zone.MapInstance.whereis(0, "Rou")
conn = spawn(fn -> Process.sleep(:infinity) end)

{:ok, handle} =
  Zone.MapInstance.enter(map, %Zone.Player{
    character: :otel_smoke,
    world_no: 0,
    map: 0,
    x: 0,
    y: 0,
    last_good: {0, 0},
    walk_speed: 0,
    run_speed: 0,
    map_type: 0,
    equipment: [],
    address: {127, 0, 0, 1},
    conn: conn
  })

{map, handle, conn}
