defmodule Proto.Hand.MiscSeedAck do
  @moduledoc "NC_MISC_SEED_ACK 0x0807 S->C"
  @enforce_keys [:seed]
  defstruct @enforce_keys
  @type t :: %__MODULE__{seed: 0..65_535}

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x0807

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<seed::little-16>>), do: {:ok, %__MODULE__{seed: seed}}
  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{seed: seed}), do: <<seed::little-16>>
end

defmodule Proto.Hand.UserClientVersionCheckReq do
  @moduledoc "NC_USER_CLIENT_VERSION_CHECK_REQ 0x0C65 C->S"
  alias Proto.Wire
  @enforce_keys [:s_version_key]
  defstruct @enforce_keys
  @type t :: %__MODULE__{s_version_key: binary()}

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x0C65

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<s_version_key::binary-size(64)>>),
    do: {:ok, %__MODULE__{s_version_key: Wire.cstr(s_version_key)}}

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{s_version_key: s_version_key}), do: Wire.pad(s_version_key, 64)
end

defmodule Proto.Hand.UserLoginAck do
  @moduledoc "NC_USER_LOGIN_ACK 0x0C0A S->C"
  alias Proto.Hand.World
  @enforce_keys [:worlds]
  defstruct @enforce_keys
  @type t :: %__MODULE__{worlds: [World.t()]}

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x0C0A

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<count::8, rest::binary-size(count * 18)>>) do
    {:ok, %__MODULE__{worlds: for(<<w::binary-size(18) <- rest>>, do: elem(World.decode(w), 1))}}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{worlds: worlds}) do
    <<length(worlds)::8, for(w <- worlds, into: <<>>, do: World.encode(w))::binary>>
  end
end

defmodule Proto.Hand.UserWorldselectAck do
  @moduledoc "NC_USER_WORLDSELECT_ACK 0x0C0C S->C"
  alias Proto.Wire
  @enforce_keys [:world_status, :wm_ip, :wm_port, :validate]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          world_status: 0..255,
          wm_ip: binary(),
          wm_port: 0..65_535,
          validate: [0..65_535]
        }

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x0C0C

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(
        <<world_status::8, wm_ip::binary-size(16), wm_port::little-16, validate::binary-size(64)>>
      ) do
    {:ok,
     %__MODULE__{
       world_status: world_status,
       wm_ip: Wire.cstr(wm_ip),
       wm_port: wm_port,
       validate: for(<<v::little-16 <- validate>>, do: v)
     }}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{
        world_status: world_status,
        wm_ip: wm_ip,
        wm_port: wm_port,
        validate: validate
      }) do
    <<world_status::8, Wire.pad(wm_ip, 16)::binary, wm_port::little-16,
      for(v <- validate, into: <<>>, do: <<v::little-16>>)::binary-size(64)>>
  end
end

defmodule Proto.Hand.UserLoginworldAck do
  @moduledoc "NC_USER_LOGINWORLD_ACK 0x0C14 S->C"
  alias Proto.Hand.Avatar
  @enforce_keys [:worldmanager, :avatar]
  defstruct @enforce_keys
  @type t :: %__MODULE__{worldmanager: 0..65_535, avatar: [Avatar.t()]}

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x0C14

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<worldmanager::little-16, count::8, rest::binary-size(count * 130)>>) do
    {:ok,
     %__MODULE__{
       worldmanager: worldmanager,
       avatar: for(<<a::binary-size(130) <- rest>>, do: elem(Avatar.decode(a), 1))
     }}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{worldmanager: worldmanager, avatar: avatar}) do
    <<worldmanager::little-16, length(avatar)::8,
      for(a <- avatar, into: <<>>, do: Avatar.encode(a))::binary>>
  end
end

defmodule Proto.Hand.AvatarCreateReq do
  @moduledoc "NC_AVATAR_CREATE_REQ 0x1401 C->S"
  alias Proto.Wire
  @enforce_keys [:slot, :name, :race_class_gender, :hair_colour_face]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slot: 0..255,
          name: binary(),
          race_class_gender: 0..255,
          hair_colour_face: binary()
        }

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1401

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(
        <<slot::8, name::binary-size(20), race_class_gender::8, hair_colour_face::binary-size(3)>>
      ) do
    {:ok,
     %__MODULE__{
       slot: slot,
       name: Wire.cstr(name),
       race_class_gender: race_class_gender,
       hair_colour_face: hair_colour_face
     }}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{
        slot: slot,
        name: name,
        race_class_gender: race_class_gender,
        hair_colour_face: hair_colour_face
      }) do
    <<slot::8, Wire.pad(name, 20)::binary, race_class_gender::8,
      hair_colour_face::binary-size(3)>>
  end
end

defmodule Proto.Hand.AvatarCreatesuccAck do
  @moduledoc "NC_AVATAR_CREATESUCC_ACK 0x1406 S->C"
  alias Proto.Hand.Avatar
  @enforce_keys [:flag, :avatar]
  defstruct @enforce_keys
  @type t :: %__MODULE__{flag: 0..255, avatar: Avatar.t()}

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1406

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<flag::8, avatar::binary-size(130)>>) do
    {:ok, avatar} = Avatar.decode(avatar)
    {:ok, %__MODULE__{flag: flag, avatar: avatar}}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{flag: flag, avatar: avatar}),
    do: <<flag::8, Avatar.encode(avatar)::binary>>
end

defmodule Proto.Hand.AvatarEraseReq do
  @moduledoc "NC_AVATAR_ERASE_REQ 0x1407 C->S"
  @enforce_keys [:slot]
  defstruct @enforce_keys
  @type t :: %__MODULE__{slot: 0..255}

  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1407

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<slot::8>>), do: {:ok, %__MODULE__{slot: slot}}
  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{slot: slot}), do: <<slot::8>>
end
