defmodule Zone.Mover do
  @moduledoc """
  The server-side mover of a player as pure functions (`docs/technical/movement.md`): a straight move from `start`
  to `goal` that takes `duration` ms from `started_at` (ms of `Clock`) and has `applied` ms of it applied.

  Integer arithmetic of the original: the distance of `ddt_Distance` FUN_004012d0, the duration and the slice points
  of `mm_Step` FUN_004be7e0 with `mm_RecalcSpeed` FUN_004bdbe0 (slices of at most 100 ms), the direction of
  `ddt_DirectSR` (`ddt_Initialize` FUN_0045fc80).
  """

  @enforce_keys [:start, :goal, :started_at, :duration]
  defstruct @enforce_keys ++ [applied: 0]

  @type t :: %__MODULE__{
          start: Zone.Grid.point(),
          goal: Zone.Grid.point(),
          started_at: integer(),
          duration: pos_integer(),
          applied: non_neg_integer()
        }

  @slice_ms 100

  @doc "The distance of a signed delta: both magnitudes halved while one is above 1024, the root rounded, doubled back."
  @spec distance(integer(), integer()) :: non_neg_integer()
  def distance(dx, dy), do: distance(abs(dx), abs(dy), 1)

  defp distance(dx, dy, m) when dx > 1024 or dy > 1024, do: distance(div(dx, 2), div(dy, 2), m * 2)
  defp distance(dx, dy, m), do: round(:math.sqrt(dx * dx + dy * dy)) * m

  @doc "The direction (0 to 179, 2 degrees each, 0 = +y, clockwise towards +x) of a signed delta. *(inferred)*"
  @spec direction(integer(), integer()) :: 0..179
  def direction(dx, dy) do
    deg = :math.atan2(dx, dy) * 180 / :math.pi()
    deg = if deg < 0, do: deg + 360, else: deg
    rem(round(deg / 2), 180)
  end

  @doc "A move from `pos` to `goal` at `speed` units per second, started at `now` ms."
  @spec start(Zone.Grid.point(), Zone.Grid.point(), pos_integer(), integer()) :: t()
  def start({px, py} = pos, {gx, gy} = goal, speed, now) when speed > 0 do
    duration = max(1, div(distance(gx - px, gy - py) * 1000, speed))
    %__MODULE__{start: pos, goal: goal, started_at: now, duration: duration}
  end

  @doc """
  The slice points up to `now`, in order, as `{applied, point}`: slices of at most 100 ms from `applied` on, the last
  one at the elapsed time. Even no time passed yields one slice (the point of `applied`, as the original). When the
  elapsed time reaches the duration every slice of the call is the goal.
  """
  @spec slices(t(), integer()) :: [{non_neg_integer(), Zone.Grid.point()}]
  def slices(%__MODULE__{} = m, now) do
    elapsed = now |> Kernel.-(m.started_at) |> min(m.duration) |> max(m.applied)
    first = if elapsed - m.applied < @slice_ms, do: elapsed, else: m.applied + @slice_ms
    first |> Stream.unfold(&next(&1, elapsed)) |> Enum.map(&{&1, point(m, &1, elapsed)})
  end

  defp next(nil, _elapsed), do: nil
  defp next(applied, applied), do: {applied, nil}
  defp next(applied, elapsed), do: {applied, applied + min(@slice_ms, elapsed - applied)}

  defp point(%__MODULE__{duration: d, goal: goal}, _applied, d), do: goal

  defp point(%__MODULE__{start: {sx, sy}, goal: {gx, gy}, duration: d}, applied, _elapsed),
    do: {axis(sx, gx, applied, d), axis(sy, gy, applied, d)}

  defp axis(s, g, applied, d) when g > s, do: s + div((g - s) * applied, d)
  defp axis(s, g, applied, d), do: s - div((s - g) * applied, d)

  @doc "Whether the whole duration is applied."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{applied: a, duration: d}), do: a == d
end
