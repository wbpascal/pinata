defmodule Proto.Hand.Avatar do
  @moduledoc "AVATAR, 130 bytes (annotations/W01.json, PROTO_AVATARINFORMATION)."
  alias Proto.Wire

  @enforce_keys [
    :chrregnum,
    :name,
    :level,
    :slot,
    :loginmap,
    :delinfo,
    :race,
    :chrclass,
    :gender,
    :hairtype,
    :haircolor,
    :faceshape,
    :equip,
    :equip_upgrade,
    :kq_handle,
    :kq_map_name,
    :kq_coord_x,
    :kq_coord_y,
    :kq_date,
    :char_id_change_flags,
    :char_id_change_row_no,
    :tutorial_state,
    :tutorial_step
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          chrregnum: non_neg_integer(),
          name: binary(),
          level: integer(),
          slot: 0..255,
          loginmap: binary(),
          delinfo: binary(),
          race: 0..3,
          chrclass: 0..31,
          gender: 0..1,
          hairtype: 0..255,
          haircolor: 0..255,
          faceshape: 0..255,
          equip: [0..65_535],
          equip_upgrade: binary(),
          kq_handle: non_neg_integer(),
          kq_map_name: binary(),
          kq_coord_x: non_neg_integer(),
          kq_coord_y: non_neg_integer(),
          kq_date: non_neg_integer(),
          char_id_change_flags: binary(),
          char_id_change_row_no: non_neg_integer(),
          tutorial_state: non_neg_integer(),
          tutorial_step: 0..255
        }

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(
        <<chrregnum::little-32, name::binary-size(20), level::little-signed-16, slot::8,
          loginmap::binary-size(12), delinfo::binary-size(5), gender::1, chrclass::5, race::2,
          hairtype::8, haircolor::8, faceshape::8, equip::binary-size(40),
          equip_upgrade::binary-size(3), kq_handle::little-32, kq_map_name::binary-size(12),
          kq_coord_x::little-32, kq_coord_y::little-32, kq_date::little-32,
          char_id_change_flags::binary-size(2), char_id_change_row_no::little-32,
          tutorial_state::little-32, tutorial_step::8>>
      ) do
    {:ok,
     %__MODULE__{
       chrregnum: chrregnum,
       name: Wire.cstr(name),
       level: level,
       slot: slot,
       loginmap: Wire.cstr(loginmap),
       delinfo: delinfo,
       race: race,
       chrclass: chrclass,
       gender: gender,
       hairtype: hairtype,
       haircolor: haircolor,
       faceshape: faceshape,
       equip: for(<<e::little-16 <- equip>>, do: e),
       equip_upgrade: equip_upgrade,
       kq_handle: kq_handle,
       kq_map_name: Wire.cstr(kq_map_name),
       kq_coord_x: kq_coord_x,
       kq_coord_y: kq_coord_y,
       kq_date: kq_date,
       char_id_change_flags: char_id_change_flags,
       char_id_change_row_no: char_id_change_row_no,
       tutorial_state: tutorial_state,
       tutorial_step: tutorial_step
     }}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{
        chrregnum: chrregnum,
        name: name,
        level: level,
        slot: slot,
        loginmap: loginmap,
        delinfo: delinfo,
        race: race,
        chrclass: chrclass,
        gender: gender,
        hairtype: hairtype,
        haircolor: haircolor,
        faceshape: faceshape,
        equip: equip,
        equip_upgrade: equip_upgrade,
        kq_handle: kq_handle,
        kq_map_name: kq_map_name,
        kq_coord_x: kq_coord_x,
        kq_coord_y: kq_coord_y,
        kq_date: kq_date,
        char_id_change_flags: char_id_change_flags,
        char_id_change_row_no: char_id_change_row_no,
        tutorial_state: tutorial_state,
        tutorial_step: tutorial_step
      }) do
    <<chrregnum::little-32, Wire.pad(name, 20)::binary, level::little-signed-16, slot::8,
      Wire.pad(loginmap, 12)::binary, delinfo::binary-size(5), gender::1, chrclass::5, race::2,
      hairtype::8, haircolor::8, faceshape::8,
      for(e <- equip, into: <<>>, do: <<e::little-16>>)::binary-size(40),
      equip_upgrade::binary-size(3), kq_handle::little-32, Wire.pad(kq_map_name, 12)::binary,
      kq_coord_x::little-32, kq_coord_y::little-32, kq_date::little-32,
      char_id_change_flags::binary-size(2), char_id_change_row_no::little-32,
      tutorial_state::little-32, tutorial_step::8>>
  end
end
