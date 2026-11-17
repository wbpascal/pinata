defmodule Proto.Macro.Packet do
  @moduledoc """
  Shape C: a small DSL that expands to struct + codec.

      use Proto.Macro.Packet, opcode: 0x0C0A      # opcode is omitted for nested structs
      field :seed, :u16                           # :u8 :u16 :u32 :i16 :i32
      field :name, {:char, 20}                    # decoded up to the first NUL, encoded zero-padded
      field :raw, {:bytes, 5}                     # untouched binary
      field :equip, {:u16s, 20}                   # list of integers
      field :avatar, Proto.Macro.Avatar           # nested struct (any module using this DSL)
      bits [gender: 1, chrclass: 5, race: 2]      # one byte, most significant bit first
      array :worlds, Proto.Macro.World, count: :u8  # must be the last entry

  The decode it emits is one function head with a literal binary pattern, like the hand-written shape.
  """

  defmacro __using__(opts) do
    quote do
      import Proto.Macro.Packet, only: [field: 2, bits: 1, array: 3]
      Module.register_attribute(__MODULE__, :proto_fields, accumulate: true)
      @proto_opcode unquote(opts[:opcode])
      @before_compile Proto.Macro.Packet
    end
  end

  defmacro field(name, type), do: quote(do: @proto_fields({:field, unquote(name), unquote(type)}))
  defmacro bits(widths), do: quote(do: @proto_fields({:bits, unquote(widths)}))

  defmacro array(name, mod, opts),
    do: quote(do: @proto_fields({:array, unquote(name), unquote(mod), unquote(opts[:count])}))

  @ints %{u8: {8, :u}, u16: {16, :u}, u32: {32, :u}, i16: {16, :s}, i32: {32, :s}}

  # an int segment: `var::little-16` or `var::little-signed-16`
  defp int_seg(v, w, :u), do: {:"::", [], [v, quote(do: little - unquote(w))]}
  defp int_seg(v, w, :s), do: {:"::", [], [v, quote(do: little - signed - unquote(w))]}
  defp bin_seg(v, n), do: {:"::", [], [v, quote(do: binary - size(unquote(n)))]}
  defp bin_seg(v), do: {:"::", [], [v, quote(do: binary)]}

  # entry: %{keys: [{key, typespec}], pat: dec segments, pre: stmts, vals: [{key, expr}], enc: enc segments, size: n | nil}
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
      size: div(w, 8)
    }
  end

  defp entry({:field, name, {:char, n}}) do
    v = Macro.var(name, nil)
    raw = Macro.var(:"#{name}_raw", nil)

    %{
      keys: [{name, quote(do: binary())}],
      pat: [bin_seg(raw, n)],
      pre: [],
      vals: [{name, quote(do: Proto.Wire.cstr(unquote(raw)))}],
      enc: [bin_seg(quote(do: Proto.Wire.pad(unquote(v), unquote(n))))],
      size: n
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
      size: n
    }
  end

  defp entry({:field, name, {:u16s, n}}) do
    raw = Macro.var(:"#{name}_raw", nil)
    v = Macro.var(name, nil)

    %{
      keys: [{name, quote(do: [0..65_535])}],
      pat: [bin_seg(raw, n * 2)],
      pre: [],
      vals: [{name, quote(do: for(<<e::little-16 <- unquote(raw)>>, do: e))}],
      enc: [bin_seg(quote(do: for(e <- unquote(v), into: <<>>, do: <<e::little-16>>)), n * 2)],
      size: n * 2
    }
  end

  defp entry({:field, name, mod}) when is_atom(mod) do
    raw = Macro.var(:"#{name}_raw", nil)
    v = Macro.var(name, nil)
    size = mod.__size__()

    %{
      keys: [{name, quote(do: unquote(mod).t())}],
      pat: [bin_seg(raw, size)],
      pre: [quote(do: {:ok, unquote(v)} = unquote(mod).decode(unquote(raw)))],
      vals: [{name, v}],
      enc: [bin_seg(quote(do: unquote(mod).encode(unquote(v))))],
      size: size
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
      size: 1
    }
  end

  defp entry({:array, name, mod, count_type}) do
    {w, :u} = Map.fetch!(@ints, count_type)
    n = Macro.var(:"#{name}_count", nil)
    rest = Macro.var(:"#{name}_rest", nil)
    v = Macro.var(name, nil)
    size = mod.__size__()

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
      size: nil
    }
  end

  defmacro __before_compile__(env) do
    entries =
      env.module |> Module.get_attribute(:proto_fields) |> Enum.reverse() |> Enum.map(&entry/1)

    opcode = Module.get_attribute(env.module, :proto_opcode)
    keys_types = Enum.flat_map(entries, & &1.keys)
    keys = Keyword.keys(keys_types)
    vals = Enum.flat_map(entries, & &1.vals)
    size = if Enum.all?(entries, & &1.size), do: entries |> Enum.map(& &1.size) |> Enum.sum()

    body =
      {:__block__, [],
       Enum.flat_map(entries, & &1.pre) ++ [quote(do: {:ok, %__MODULE__{unquote_splicing(vals)}})]}

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
      def __size__, do: unquote(size)

      @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
      def decode(<<unquote_splicing(Enum.flat_map(entries, & &1.pat))>>), do: unquote(body)
      def decode(_), do: {:error, :bad_size}

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{unquote_splicing(destructure)}),
        do: <<unquote_splicing(Enum.flat_map(entries, & &1.enc))>>
    end
  end
end
