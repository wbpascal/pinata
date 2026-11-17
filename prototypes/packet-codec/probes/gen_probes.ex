defmodule Proto.Probes.Gen do
  @moduledoc "Deliberately wrong callers. Each function has exactly one defect (see the comment above it)."
  alias Proto.Gen.UserLoginAck
  alias Proto.Gen.UserWorldselectAck

  # 1 defect: reads a misspelt field (wm_prot)
  @spec unknown_field(UserWorldselectAck.t()) :: term()
  def unknown_field(%UserWorldselectAck{} = p), do: p.wm_prot

  # 2 defect: wm_port is a string, not an integer
  @spec wrong_field_type() :: binary()
  def wrong_field_type do
    UserWorldselectAck.encode(%UserWorldselectAck{
      world_status: 6,
      wm_ip: "172.16.42.214",
      wm_port: "9110",
      validate: List.duplicate(0, 32)
    })
  end

  # 3 defect: decode returns {:ok, _} | {:error, _}, the tag is forgotten
  @spec untagged_result(binary()) :: UserWorldselectAck.t()
  def untagged_result(bin) do
    %UserWorldselectAck{} = UserWorldselectAck.decode(bin)
  end

  # 4 defect: the list holds an atom, not a World
  @spec wrong_element() :: binary()
  def wrong_element, do: UserLoginAck.encode(%UserLoginAck{worlds: [:not_a_world]})

  # 5 defect: world_status is an integer, compared with an atom
  @spec impossible_compare(UserWorldselectAck.t()) :: 0 | 1
  def impossible_compare(%UserWorldselectAck{} = p) do
    case p.world_status do
      :open -> 1
      _ -> 0
    end
  end
end
