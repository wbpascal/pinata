# PROTOTYPE for issue 14 (throwaway, not for master). Shape A: Elixir source generated from docs/protocol JSON.
#
#   elixir gen.exs              writes lib/gen/generated.ex
#   elixir gen.exs --coverage   writes nothing, counts how many login/wm packets the generator can handle
#   PROTO_DOCS=/other/dir elixir gen.exs   read another copy of docs/protocol (correction experiment)
defmodule Gen do
  @docs System.get_env("PROTO_DOCS") || Path.expand("../../docs/protocol", __DIR__)
  @out Path.join(__DIR__, "lib/gen/generated.ex")

  # (server, opcode, dir) of the 8 packets of the prototype
  @packets [
    {"login", 0x0807, "S→C"},
    {"login", 0x0C65, "C→S"},
    {"login", 0x0C0A, "S→C"},
    {"login", 0x0C0C, "S→C"},
    {"wm", 0x0C14, "S→C"},
    {"wm", 0x1401, "C→S"},
    {"wm", 0x1406, "S→C"},
    {"wm", 0x1407, "C→S"}
  ]

  # OVERRIDES: the annotation types the bitfield byte as plain u8 and keeps the bit layout only in the note.
  # Field name -> bit widths, most significant bit first. Every entry is a finding (FINDINGS.md).
  @bit_overrides %{"shape.race|chrclass|gender" => [gender: 1, chrclass: 5, race: 2]}

  @ints %{"u8" => {8, :u}, "u16" => {16, :u}, "u32" => {32, :u}, "u64" => {64, :u},
          "i16" => {16, :s}, "i32" => {32, :s}, "i64" => {64, :s}, "f32" => {32, :f}}
  @reserved ~w(end do fn in nil true false when and or not after else catch rescue)

  # ---- merge rule, copied from load_docs() in tools/protocol-re/pcap_decode.py ----
  def load do
    read = &(&1 |> File.read!() |> JSON.decode!())
    base = read.(Path.join(@docs, "annotations.json"))
    files = Path.join(@docs, "annotations/*.json") |> Path.wildcard() |> Enum.sort()

    Enum.reduce([base | Enum.map(files, read)], {%{}, %{}}, fn a, {structs, packets} ->
      structs = Map.merge(structs, a["structs"] || %{})

      packets =
        for {srv, d} <- a["packets"] || %{}, {op, v} <- d, reduce: packets do
          acc -> Map.put(acc, {srv, hex(op), dir(v["dir"])}, v)
        end

      {structs, packets}
    end)
  end

  defp hex("0x" <> h), do: String.to_integer(h, 16)

  defp dir(d) do
    case d |> to_string() |> String.split("→") |> Enum.map(&String.trim/1) do
      ["C", x] when x != "C" -> "C→S"
      [x, "C"] when x != "C" -> "S→C"
      _ -> d
    end
  end

  def pdb_structs, do: Path.join(@docs, "pdb2016-layouts.json") |> File.read!() |> JSON.decode!() |> Map.fetch!("structs")

  # ---- field names: mechanical rule ----
  defp ident(raw) do
    s =
      raw
      |> String.replace(~r/\s*\(.*\)\s*$/, "")
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    cond do
      not (s =~ ~r/^[a-z][a-z0-9_]*$/) -> {:error, "field name `#{raw}` is not an identifier"}
      s in @reserved -> {:error, "field name `#{raw}` is a reserved word"}
      true -> {:ok, s}
    end
  end

  # ---- type grammar ----
  defp parse_type(t, ctx) do
    cond do
      Map.has_key?(@ints, t) -> {:int, elem(@ints[t], 0), elem(@ints[t], 1)}
      m = Regex.run(~r/^char\[(\d+)\]$/, t) -> {:char, String.to_integer(Enum.at(m, 1))}
      m = Regex.run(~r/^(?:u8|bytes)\[(\d+)\]$/, t) -> {:bytes, String.to_integer(Enum.at(m, 1))}
      m = Regex.run(~r/^u(16|32)\[(\d+)\]$/, t) -> {:list, String.to_integer(Enum.at(m, 1)), String.to_integer(Enum.at(m, 2))}
      t == "bytes" -> :rest
      m = Regex.run(~r/^([A-Za-z_]\w*)\[([A-Za-z_]\w*)\]$/, t) -> array_type(m, ctx)
      Map.has_key?(ctx.structs, t) -> struct_type(t, ctx)
      true -> {:error, "unsupported type `#{t}`"}
    end
  end

  defp array_type([_, st, count], ctx) do
    if Map.has_key?(ctx.structs, st), do: with({:struct, mod, size} <- struct_type(st, ctx), do: {:array, mod, size, count}), else: {:error, "unsupported type `#{st}[#{count}]`"}
  end

  defp struct_type(name, ctx) do
    case analyze(ctx.structs[name]["fields"], ctx, true) do
      {items, []} ->
        sum = if Enum.all?(items, & &1.size), do: Enum.sum(Enum.map(items, & &1.size))

        cond do
          sum == nil -> {:error, "struct #{name} is variable-length"}
          sum != ctx.structs[name]["size"] -> {:error, "struct #{name}: declared size #{ctx.structs[name]["size"]} != field sum #{sum}"}
          true -> {:struct, mod_name(ctx.prefix, name), sum}
        end

      {_, [first | _]} ->
        {:error, "struct #{name}: #{first}"}
    end
  end

  defp mod_name(prefix, name), do: prefix <> "." <> (name |> String.downcase() |> Macro.camelize())

  # ---- one field list -> items (strings of generated code) or errors ----
  def analyze(fields, ctx, nested? \\ false) do
    {items, errors, _off, _names} =
      Enum.reduce(Enum.with_index(fields), {[], [], 0, []}, fn {[off, type, raw | _], idx}, {items, errs, run, names} ->
        errs = if off == run, do: errs, else: ["offset #{off} != running size #{run} (gap or overlap)" | errs]
        override = if ctx.overrides? and type == "u8", do: @bit_overrides[raw]
        last? = idx == length(fields) - 1

        case {override, parse_type(type, ctx)} do
          {widths, _} when widths != nil ->
            {items ++ [bits_item(widths)], errs, off + 1, names ++ Keyword.keys(widths)}

          {_, {:error, e}} ->
            {items, [e | errs], off, names}

          {_, {:array, mod, size, count}} ->
            prev = List.last(items)
            cond do
              nested? or not last? -> {items, ["array `#{type}` is not the last field of a packet" | errs], off, names}
              prev == nil or prev.raw != count or prev.count_int == nil -> {items, ["count field `#{count}` is not the preceding integer field" | errs], off, names}
              true -> name_it(raw, &array_item(&1, mod, size, prev.count_int), Enum.drop(items, -1), errs, off, names -- [prev.name])
            end

          {_, :rest} ->
            if last?, do: name_it(raw, &rest_item/1, items, errs, off, names), else: {items, ["`bytes` is not the last field" | errs], off, names}

          {_, kind} ->
            name_it(raw, &item(&1, kind), items, errs, off, names)
        end
      end)

    {items, Enum.reverse(errors)}
  end

  defp name_it(raw, build, items, errs, off, names) do
    case ident(raw) do
      {:error, e} ->
        {items, [e | errs], off, names}

      {:ok, n} ->
        errs = if n in names, do: ["field name `#{raw}` gives duplicate identifier `#{n}`" | errs], else: errs
        it = build.(n) |> Map.merge(%{raw: raw, name: n})
        {items ++ [it], errs, off + (it.size || 0), [n | names]}
    end
  end

  # item: %{keys: [{k, typespec}], pat: [..], pre: [..], vals: [{k, expr}], enc: [..], size: n | nil, count_int: bits | nil}
  defp item(n, {:int, _, :f}), do: simple(n, "float()", "#{n}::little-float-32", 4, nil)
  defp item(n, {:int, 8, s}), do: simple(n, if(s == :u, do: "0..255", else: "integer()"), "#{n}::#{if s == :s, do: "signed-"}8", 1, {8, s})
  defp item(n, {:int, w, s}), do: simple(n, if(s == :u, do: "non_neg_integer()", else: "integer()"), "#{n}::little-#{if s == :s, do: "signed-"}#{w}", div(w, 8), {w, s})

  defp item(n, {:char, c}),
    do: %{keys: [{n, "binary()"}], pat: ["#{n}_raw::binary-size(#{c})"], pre: [], vals: [{n, "Proto.Wire.cstr(#{n}_raw)"}], enc: ["Proto.Wire.pad(#{n}, #{c})::binary"], size: c, count_int: nil}

  defp item(n, {:bytes, c}), do: simple(n, "binary()", "#{n}::binary-size(#{c})", c, nil)

  defp item(n, {:list, w, c}) do
    ty = if w == 16, do: "[0..65_535]", else: "[non_neg_integer()]"
    %{keys: [{n, ty}], pat: ["#{n}_raw::binary-size(#{c * div(w, 8)})"], pre: [], vals: [{n, "for(<<e::little-#{w} <- #{n}_raw>>, do: e)"}],
      enc: ["for(e <- #{n}, into: <<>>, do: <<e::little-#{w}>>)::binary-size(#{c * div(w, 8)})"], size: c * div(w, 8), count_int: nil}
  end

  defp item(n, {:struct, mod, size}),
    do: %{keys: [{n, "#{mod}.t()"}], pat: ["#{n}_raw::binary-size(#{size})"], pre: ["{:ok, #{n}} = #{mod}.decode(#{n}_raw)"], vals: [{n, n}], enc: ["#{mod}.encode(#{n})::binary"], size: size, count_int: nil}

  defp simple(n, ty, seg, size, count_int), do: %{keys: [{n, ty}], pat: [seg], pre: [], vals: [{n, n}], enc: [seg], size: size, count_int: count_int}

  defp bits_item(widths) do
    segs = for {k, w} <- widths, do: "#{k}::#{w}"
    %{keys: for({k, w} <- widths, do: {to_string(k), "0..#{Integer.pow(2, w) - 1}"}), pat: segs, pre: [], vals: for({k, _} <- widths, do: {to_string(k), to_string(k)}), enc: segs, size: 1, count_int: nil, raw: nil, name: nil}
  end

  defp rest_item(n), do: %{keys: [{n, "binary()"}], pat: ["#{n}::binary"], pre: [], vals: [{n, n}], enc: ["#{n}::binary"], size: nil, count_int: nil}

  defp array_item(n, mod, size, {cw, :u}) do
    %{keys: [{n, "[#{mod}.t()]"}],
      pat: ["#{n}_count::#{if cw == 8, do: 8, else: "little-#{cw}"}", "#{n}_rest::binary-size(#{n}_count * #{size})"], pre: [],
      vals: [{n, "for(<<chunk::binary-size(#{size}) <- #{n}_rest>>, do: elem(#{mod}.decode(chunk), 1))"}],
      enc: ["length(#{n})::#{if cw == 8, do: 8, else: "little-#{cw}"}", "for(e <- #{n}, into: <<>>, do: #{mod}.encode(e))::binary"], size: nil, count_int: nil}
  end

  # ---- emit ----
  defp emit(mod, items, opcode, doc) do
    keys = Enum.flat_map(items, & &1.keys)
    names = Enum.map(keys, &elem(&1, 0))
    vals = Enum.flat_map(items, & &1.vals) |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)
    pre = items |> Enum.flat_map(& &1.pre) |> Enum.join("\n")
    pat = items |> Enum.flat_map(& &1.pat) |> Enum.join(", ")
    enc = items |> Enum.flat_map(& &1.enc) |> Enum.join(", ")
    ty = Enum.map_join(keys, ", ", fn {k, t} -> "#{k}: #{t}" end)
    opc = if opcode, do: "@spec opcode() :: 0..0xFFFF\ndef opcode, do: #{opcode}\n", else: ""

    """
    defmodule #{mod} do
      @moduledoc #{inspect(doc)}
      @enforce_keys [#{Enum.map_join(names, ", ", &":#{&1}")}]
      defstruct @enforce_keys
      @type t :: %__MODULE__{#{ty}}
      #{opc}
      @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
      def decode(<<#{pat}>>) do
        #{pre}
        {:ok, %__MODULE__{#{vals}}}
      end

      def decode(_), do: {:error, :bad_size}

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{#{Enum.map_join(names, ", ", &"#{&1}: #{&1}")}}), do: <<#{enc}>>
    end
    """
  end

  def opname(pkt, op) do
    case pkt["name"] do
      "NC_" <> rest -> {:ok, rest |> String.downcase() |> Macro.camelize()}
      _ -> {:fallback, "Op" <> (op |> Integer.to_string(16) |> String.pad_leading(4, "0"))}
    end
  end

  def main(["--coverage"]) do
    {structs, packets} = load()
    ctx = %{structs: Map.merge(pdb_structs(), structs), prefix: "Proto.Gen", overrides?: false}

    rows =
      for {{srv, op, d}, p} <- Enum.sort(packets), srv in ["login", "wm"], d in ["C→S", "S→C"] do
        {_, errs} = analyze(p["fields"], ctx)
        {srv, op, d, p["name"], Enum.uniq(errs)}
      end

    ok = Enum.count(rows, &(elem(&1, 4) == []))
    fallback = Enum.count(rows, fn {_, op, _, n, _} -> opname(%{"name" => n}, op) |> elem(0) == :fallback end)
    IO.puts("docs: #{@docs}")
    IO.puts("login/wm packets with dir C→S or S→C in the merged annotations: #{length(rows)}")
    IO.puts("  generated without override (types in grammar, names unique identifiers, offsets contiguous): #{ok}")
    IO.puts("  not generated: #{length(rows) - ok}")
    IO.puts("  (#{fallback} of all #{length(rows)} have no official NC_ name; the generator falls back to Op<hex> module names)")
    IO.puts("by server: " <> inspect(rows |> Enum.group_by(&elem(&1, 0)) |> Map.new(fn {s, r} -> {s, {length(r), Enum.count(r, &(elem(&1, 4) == []))}} end)) <> " ({total, generated})")
    IO.puts("\ntop 10 reasons (packets affected):")

    rows
    |> Enum.flat_map(&elem(&1, 4))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {r, n} -> {-n, r} end)
    |> Enum.take(10)
    |> Enum.each(fn {r, n} -> IO.puts("  #{String.pad_leading(to_string(n), 4)}  #{r}") end)
  end

  def main([]) do
    {structs, packets} = load()
    ctx = %{structs: Map.merge(pdb_structs(), structs), prefix: "Proto.Gen", overrides?: true}

    pkts =
      for {srv, op, d} = key <- @packets do
        p = Map.fetch!(packets, key)
        {items, errs} = analyze(p["fields"], ctx)
        if errs != [], do: raise("#{srv} 0x#{Integer.to_string(op, 16)}: #{inspect(errs)}")
        {:ok, n} = opname(p, op)
        _ = d
        {"Proto.Gen." <> n, items, op, "#{p["name"]} 0x#{op |> Integer.to_string(16) |> String.pad_leading(4, "0")} #{d}"}
      end

    used = pkts |> Enum.flat_map(fn {_, items, _, _} -> Enum.flat_map(items, & &1.keys) end) |> Enum.flat_map(fn {_, t} -> Regex.scan(~r/Proto\.Gen\.(\w+)\.t\(\)/, t) end) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    structs_src =
      for name <- Enum.sort(used) do
        key = Enum.find(Map.keys(ctx.structs), &(String.downcase(&1) |> Macro.camelize() == name))
        {items, []} = analyze(ctx.structs[key]["fields"], ctx, true)
        emit("Proto.Gen." <> name, items, nil, "#{key}, #{ctx.structs[key]["size"]} bytes")
      end

    pkts_src = for {m, items, op, doc} <- pkts, do: emit(m, items, "0x" <> String.upcase(Integer.to_string(op, 16) |> String.pad_leading(4, "0")), doc)

    header = "# GENERATED by gen.exs from docs/protocol/*.json. DO NOT EDIT: change the JSON and re-run `elixir gen.exs`.\n\n"
    code = Enum.join(structs_src ++ pkts_src, "\n") |> Code.format_string!() |> IO.iodata_to_binary()
    File.write!(@out, header <> code <> "\n")
    IO.puts("wrote #{@out}")
  end
end

Gen.main(System.argv())
