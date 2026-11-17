defmodule Proto.Macro.World do
  use Proto.Macro.Packet
  field :world_no, :u8
  field :world_name, {:char, 16}
  field :status, :u8
end

defmodule Proto.Macro.Avatar do
  use Proto.Macro.Packet
  field :chrregnum, :u32
  field :name, {:char, 20}
  field :level, :i16
  field :slot, :u8
  field :loginmap, {:char, 12}
  field :delinfo, {:bytes, 5}
  bits gender: 1, chrclass: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
  field :equip, {:u16s, 20}
  field :equip_upgrade, {:bytes, 3}
  field :kq_handle, :u32
  field :kq_map_name, {:char, 12}
  field :kq_coord_x, :u32
  field :kq_coord_y, :u32
  field :kq_date, :u32
  field :char_id_change_flags, {:bytes, 2}
  field :char_id_change_row_no, :u32
  field :tutorial_state, :u32
  field :tutorial_step, :u8
end

defmodule Proto.Macro.MiscSeedAck do
  use Proto.Macro.Packet, opcode: 0x0807
  field :seed, :u16
end

defmodule Proto.Macro.UserClientVersionCheckReq do
  use Proto.Macro.Packet, opcode: 0x0C65
  field :s_version_key, {:char, 64}
end

defmodule Proto.Macro.UserLoginAck do
  use Proto.Macro.Packet, opcode: 0x0C0A
  array :worlds, Proto.Macro.World, count: :u8
end

defmodule Proto.Macro.UserWorldselectAck do
  use Proto.Macro.Packet, opcode: 0x0C0C
  field :world_status, :u8
  field :wm_ip, {:char, 16}
  field :wm_port, :u16
  field :validate, {:u16s, 32}
end

defmodule Proto.Macro.UserLoginworldAck do
  use Proto.Macro.Packet, opcode: 0x0C14
  field :worldmanager, :u16
  array :avatar, Proto.Macro.Avatar, count: :u8
end

defmodule Proto.Macro.AvatarCreateReq do
  use Proto.Macro.Packet, opcode: 0x1401
  field :slot, :u8
  field :name, {:char, 20}
  field :race_class_gender, :u8
  field :hair_colour_face, {:bytes, 3}
end

defmodule Proto.Macro.AvatarCreatesuccAck do
  use Proto.Macro.Packet, opcode: 0x1406
  field :flag, :u8
  field :avatar, Proto.Macro.Avatar
end

defmodule Proto.Macro.AvatarEraseReq do
  use Proto.Macro.Packet, opcode: 0x1407
  field :slot, :u8
end
