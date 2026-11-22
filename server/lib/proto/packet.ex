defmodule Proto.Packet do
  @moduledoc """
  Declarative packet definitions (ADR 0007): a small DSL that expands to struct + codec.

      use Proto.Packet, opcode: 0x0C0A            # opcode is omitted for nested structs
      field :seed, :u16                           # :u8 :u16 :u32 :u64 :i8 :i16 :i32
      field :name, {:char, 20}                    # decoded up to the first NUL, encoded zero-padded
      field :raw, {:bytes, 5}                     # untouched binary
      field :equip, {:u16s, 20}                   # list of integers
      field :text, {:counted, :u8}                # u8 length, then that many bytes; must be the last entry
      field :avatar, MyApp.Avatar                 # nested struct (any module using this DSL)
      bits [gender: 1, chrclass: 5, race: 2]      # one byte, most significant bit first
      array :worlds, MyApp.World, count: :u8      # must be the last entry

  Rules: a char field is cut at its first NUL and zero-padded on encode; lengths are strict, any other size
  gives `{:error, :bad_size}`; an array count and the length of a counted field are not struct fields.

  `__packet__/0` has `layout`: `{name, offset, size, sub}` per key (byte offset in the payload; `size` nil and `offset`
  of the count for an array or a counted field; `sub` is nil, a nested module or `{:array, module, count_bytes}`), used by the replay masks.

  The decode is one function head with a literal binary pattern.
  """

  defmacro __using__(opts) do
    quote do
      import Proto.Packet, only: [field: 2, bits: 1, array: 3]
      Module.register_attribute(__MODULE__, :proto_fields, accumulate: true)
      @proto_opcode unquote(opts[:opcode])
      @before_compile Proto.Packet
    end
  end

  defmacro field(name, type), do: quote(do: @proto_fields({:field, unquote(name), unquote(type)}))
  defmacro bits(widths), do: quote(do: @proto_fields({:bits, unquote(widths)}))

  defmacro array(name, mod, opts),
    do: quote(do: @proto_fields({:array, unquote(name), unquote(mod), unquote(opts[:count])}))

  @ints %{u8: {8, :u}, u16: {16, :u}, u32: {32, :u}, u64: {64, :u}, i8: {8, :s}, i16: {16, :s}, i32: {32, :s}}

  # an int segment: `var::little-16` or `var::little-signed-16`
  defp int_seg(v, w, :u), do: {:"::", [], [v, quote(do: little - unquote(w))]}
  defp int_seg(v, w, :s), do: {:"::", [], [v, quote(do: little - signed - unquote(w))]}
  defp bin_seg(v, n), do: {:"::", [], [v, quote(do: binary - size(unquote(n)))]}
  defp bin_seg(v), do: {:"::", [], [v, quote(do: binary)]}

  # entry: %{keys: [{key, typespec}], pat: dec segments, pre: stmts, vals: [{key, expr}], enc: enc segments, size: n | nil, doc: [{name, type_text}]}
  defp entry({:field, name, type}) when is_map_key(@ints, type) do
    {w, sign} = Map.fetch!(@ints, type)
    v = Macro.var(name, nil)
    ty = if sign == :u, do: quote(do: non_neg_integer()), else: quote(do: integer())

    %{
      keys: [{name, ty}],
      pat: [int_seg(v, w, sign)],
      pre: [],
      vals: [{name, v}],
      enc: [int_seg(v, w, sign)],
      size: div(w, 8),
      sub: nil,
      doc: [{name, Atom.to_string(type)}]
    }
  end

  defp entry({:field, name, {:char, n}}) do
    v = Macro.var(name, nil)
    raw = Macro.var(name, :raw)

    %{
      keys: [{name, quote(do: binary())}],
      pat: [bin_seg(raw, n)],
      pre: [],
      vals: [{name, quote(do: Proto.Packet.cstr(unquote(raw)))}],
      enc: [bin_seg(quote(do: Proto.Packet.pad(unquote(v), unquote(n))))],
      size: n,
      sub: nil,
      doc: [{name, "char[#{n}]"}]
    }
  end

  defp entry({:field, name, {:bytes, n}}) do
    v = Macro.var(name, nil)

    %{
      keys: [{name, quote(do: binary())}],
      pat: [bin_seg(v, n)],
      pre: [],
      vals: [{name, v}],
      enc: [bin_seg(v, n)],
      size: n,
      sub: nil,
      doc: [{name, "bytes[#{n}]"}]
    }
  end

  defp entry({:field, name, {:u16s, n}}) do
    raw = Macro.var(name, :raw)
    v = Macro.var(name, nil)

    %{
      keys: [{name, quote(do: [0..65_535])}],
      pat: [bin_seg(raw, n * 2)],
      pre: [],
      vals: [{name, quote(do: for(<<e::little-16 <- unquote(raw)>>, do: e))}],
      enc: [bin_seg(quote(do: for(e <- unquote(v), into: <<>>, do: <<e::little-16>>)), n * 2)],
      size: n * 2,
      sub: nil,
      doc: [{name, "u16[#{n}]"}]
    }
  end

  defp entry({:field, name, {:counted, count_type}}) do
    {w, :u} = Map.fetch!(@ints, count_type)
    n = Macro.var(name, :count)
    v = Macro.var(name, nil)

    %{
      keys: [{name, quote(do: binary())}],
      pat: [int_seg(n, w, :u), {:"::", [], [v, quote(do: binary - size(unquote(n)))]}],
      pre: [],
      vals: [{name, v}],
      enc: [int_seg(quote(do: byte_size(unquote(v))), w, :u), bin_seg(v)],
      size: nil,
      sub: nil,
      doc: [{name, "bytes[count: #{count_type}]"}]
    }
  end

  defp entry({:field, name, mod}) when is_atom(mod) do
    raw = Macro.var(name, :raw)
    v = Macro.var(name, nil)
    size = mod.__packet__().size

    %{
      keys: [{name, quote(do: unquote(mod).t())}],
      pat: [bin_seg(raw, size)],
      pre: [quote(do: {:ok, unquote(v)} = unquote(mod).decode(unquote(raw)))],
      vals: [{name, v}],
      enc: [bin_seg(quote(do: unquote(mod).encode(unquote(v))))],
      size: size,
      sub: mod,
      doc: [{name, inspect(mod)}]
    }
  end

  defp entry({:bits, widths}) do
    vars = for {k, _} <- widths, do: Macro.var(k, nil)
    segs = for {{_, w}, v} <- Enum.zip(widths, vars), do: {:"::", [], [v, w]}

    %{
      keys: for({k, w} <- widths, do: {k, quote(do: 0..unquote(Integer.pow(2, w) - 1))}),
      pat: segs,
      pre: [],
      vals: for({{k, _}, v} <- Enum.zip(widths, vars), do: {k, v}),
      enc: segs,
      size: 1,
      sub: nil,
      doc: for({k, w} <- widths, do: {k, "bit:#{w}"})
    }
  end

  defp entry({:array, name, mod, count_type}) do
    {w, :u} = Map.fetch!(@ints, count_type)
    n = Macro.var(name, :count)
    rest = Macro.var(name, :rest)
    v = Macro.var(name, nil)
    size = mod.__packet__().size

    %{
      keys: [{name, quote(do: [unquote(mod).t()])}],
      pat: [
        int_seg(n, w, :u),
        {:"::", [], [rest, quote(do: binary - size(unquote(n) * unquote(size)))]}
      ],
      pre: [],
      # run-time loop over the elements only
      vals: [
        {name,
         quote(
           do:
             for(<<chunk::binary-size(unquote(size)) <- unquote(rest)>>,
               do: elem(unquote(mod).decode(chunk), 1)
             )
         )}
      ],
      enc: [
        int_seg(quote(do: length(unquote(v))), w, :u),
        bin_seg(quote(do: for(e <- unquote(v), into: <<>>, do: unquote(mod).encode(e))))
      ],
      size: nil,
      sub: {:array, mod, div(w, 8)},
      doc: [{name, "#{inspect(mod)}[count: #{count_type}]"}]
    }
  end

  # nil when any entry is variable-sized
  defp total_size(entries) do
    if Enum.all?(entries, & &1.size), do: entries |> Enum.map(& &1.size) |> Enum.sum()
  end

  defp layout(entries) do
    {layout, _} =
      Enum.flat_map_reduce(entries, 0, fn e, off ->
        {for({k, _} <- e.keys, do: {k, off, e.size, e.sub}), off + (e.size || 0)}
      end)

    layout
  end

  defmacro __before_compile__(env) do
    entries =
      env.module |> Module.get_attribute(:proto_fields) |> Enum.reverse() |> Enum.map(&entry/1)

    opcode = Module.get_attribute(env.module, :proto_opcode)
    keys_types = Enum.flat_map(entries, & &1.keys)
    keys = Keyword.keys(keys_types)
    doc_fields = Enum.flat_map(entries, & &1.doc)
    vals = Enum.flat_map(entries, & &1.vals)
    size = total_size(entries)

    layout = layout(entries)

    body =
      {:__block__, [], Enum.flat_map(entries, & &1.pre) ++ [quote(do: {:ok, %__MODULE__{unquote_splicing(vals)}})]}

    destructure = for k <- keys, do: {k, Macro.var(k, nil)}

    quote do
      @enforce_keys unquote(keys)
      defstruct unquote(keys)
      @type t :: %__MODULE__{unquote_splicing(keys_types)}

      unquote(
        if opcode do
          quote do
            @spec opcode() :: 0..0xFFFF
            def opcode, do: unquote(opcode)
          end
        end
      )

      @doc false
      @spec __packet__() :: map()
      def __packet__,
        do: %{size: unquote(size || :variable), fields: unquote(doc_fields), layout: unquote(Macro.escape(layout))}

      @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
      def decode(<<unquote_splicing(Enum.flat_map(entries, & &1.pat))>>), do: unquote(body)
      def decode(_), do: {:error, :bad_size}

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{unquote_splicing(destructure)}),
        do: <<unquote_splicing(Enum.flat_map(entries, & &1.enc))>>
    end
  end

  @doc "char[N] decode: the bytes before the first NUL (no character-set conversion)."
  @spec cstr(binary()) :: binary()
  def cstr(bin), do: bin |> :binary.split(<<0>>) |> hd()

  @doc "char[N] encode: zero-pad to n bytes, raise when longer."
  @spec pad(binary(), non_neg_integer()) :: binary()
  def pad(bin, n) when byte_size(bin) <= n, do: bin <> :binary.copy(<<0>>, n - byte_size(bin))
  def pad(bin, n), do: raise(ArgumentError, "#{inspect(bin)} longer than char[#{n}]")
end
