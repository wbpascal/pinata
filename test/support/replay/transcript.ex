defmodule Replay.Transcript do
  @moduledoc "Parser of transcript files (format: `docs/technical/testing.md`). Times are integer microseconds."

  @enforce_keys [:capture, :start, :packets]
  defstruct [:capture, :start, :packets]

  @type packet :: %{
          index: pos_integer(),
          time: integer(),
          conn: String.t(),
          dir: :client | :server,
          opcode: 0..0xFFFF,
          payload: binary()
        }
  @type t :: %__MODULE__{capture: String.t(), start: integer(), packets: [packet()]}

  @doc "Reads and parses a transcript file."
  @spec read!(Path.t()) :: t()
  def read!(path), do: path |> File.read!() |> parse!()

  @doc "Parses transcript text; raises `ArgumentError` naming the line of a malformed line."
  @spec parse!(String.t()) :: t()
  def parse!(text) do
    lines = text |> String.split("\n", trim: true) |> Enum.with_index(1)

    {headers, rows} = Enum.split_with(lines, fn {l, _} -> String.starts_with?(l, "#") end)

    {capture, start} =
      case headers do
        [{"# transcript of " <> rest, _}, {"# start " <> start, n}] ->
          {rest |> String.split(" ") |> hd() |> String.replace_suffix(".pcapng", ""), micros!(start, n)}

        _ ->
          raise ArgumentError, "transcript needs the two header lines"
      end

    packets =
      rows |> Enum.with_index(1) |> Enum.map(fn {{line, n}, index} -> packet!(line, n, index) end)

    %__MODULE__{capture: capture, start: start, packets: packets}
  end

  defp packet!(line, n, index) do
    with [time, conn, dir, "0x" <> op, payload] <- String.split(line, " "),
         {:ok, dir} <- dir(dir),
         {opcode, ""} <- Integer.parse(op, 16),
         {:ok, payload} <- payload(payload) do
      %{index: index, time: micros!(time, n), conn: conn, dir: dir, opcode: opcode, payload: payload}
    else
      _ -> raise ArgumentError, "malformed transcript line #{n}: #{inspect(line)}"
    end
  end

  defp dir("C"), do: {:ok, :client}
  defp dir("S"), do: {:ok, :server}
  defp dir(_), do: :error

  defp payload("-"), do: {:ok, <<>>}
  defp payload(hex), do: Base.decode16(hex, case: :lower)

  defp micros!(text, n) do
    with [sec, frac] <- String.split(text, "."),
         {sec, ""} <- Integer.parse(sec),
         {frac, ""} <- Integer.parse(frac) do
      sec * 1_000_000 + frac
    else
      _ -> raise ArgumentError, "malformed time on transcript line #{n}: #{inspect(text)}"
    end
  end
end
