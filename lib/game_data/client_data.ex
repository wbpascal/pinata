defmodule GameData.ClientData do
  @moduledoc """
  The Client data check of `0x1801`: the client sends the MD5 (lower-case hex text) of 49 of its tables, each over
  the whole file with its body (from 0x24) decrypted. The server compares them with the same hashes of its own copy.
  Flow: `docs/technical/flows/enter-world.md`.
  """

  @files ~w(
    shn/AbState.shn shn/ActiveSkill.shn shn/CharacterTitleData.shn shn/ChargedEffect.shn shn/ClassName.shn
    shn/Gather.shn shn/GradeItemOption.shn shn/ItemDismantle.shn shn/ItemInfo.shn shn/MapInfo.shn
    shn/MiniHouse.shn shn/MiniHouseFurniture.shn shn/MiniHouseObjAni.shn shn/MobInfo.shn shn/PassiveSkill.shn
    shn/Riding.shn shn/SubAbState.shn shn/UpgradeInfo.shn shn/WeaponAttrib.shn shn/WeaponTitleData.shn
    shn/MiniHouseFurnitureObjEffect.shn shn/MiniHouseEndure.shn shn/DiceDividind.shn shn/ActionViewInfo.shn
    shn/MapLinkPoint.shn shn/MapWayPoint.shn shn/View/AbStateView.shn shn/View/ActiveSkillView.shn
    shn/View/CharacterTitleStateView.shn shn/View/EffectViewInfo.shn shn/View/ItemShopView.shn
    shn/View/ItemViewInfo.shn shn/View/MapViewInfo.shn shn/View/MobViewInfo.shn shn/View/NPCViewInfo.shn
    shn/View/PassiveSkillView.shn shn/View/ProduceView.shn shn/View/CollectCardView.shn shn/View/GTIView.shn
    shn/View/ItemViewEquipTypeInfo.shn shn/SingleData.shn shn/MarketSearchInfo.shn shn/ItemMoney.shn
    shn/PupMain.shn shn/ChatColor.shn shn/TermExtendMatch.shn shn/MinimonInfo.shn shn/MinimonAutoUseItem.shn
    shn/ChargedDeletableBuff.shn
  )

  @type checksum :: {table :: String.t(), md5_hex :: binary()}

  @doc "The 49 files of the check, relative to the data directory, in the order of the client's checksums."
  @spec files() :: [String.t()]
  def files, do: @files

  @doc "The checksums of the 49 files of `data_dir`. All problems come back together, one line per file."
  @spec checksums(Path.t()) :: {:ok, [checksum()]} | {:error, [String.t(), ...]}
  def checksums(data_dir) do
    results = Enum.map(@files, &checksum(data_dir, &1))

    case for {:error, line} <- results, do: line do
      [] -> {:ok, for({:ok, checksum} <- results, do: checksum)}
      lines -> {:error, lines}
    end
  end

  defp checksum(data_dir, rel) do
    with {:ok, file} <- read(data_dir, rel),
         {:ok, plain} <- decrypt(rel, file) do
      {:ok, {Path.basename(rel), :md5 |> :crypto.hash(plain) |> Base.encode16(case: :lower)}}
    end
  end

  defp read(data_dir, rel) do
    case File.read(GameData.DataFile.path(data_dir, rel)) do
      {:ok, file} -> {:ok, file}
      {:error, :enoent} -> {:error, "#{rel}: file not found (needed for the Client data check)"}
      {:error, reason} -> {:error, "#{rel}: #{:file.format_error(reason)}"}
    end
  end

  defp decrypt(rel, file) do
    case GameData.Shn.decrypt(file) do
      {:ok, plain} -> {:ok, plain}
      {:error, message} -> {:error, "#{rel}: #{message}"}
    end
  end

  @doc "The first of the client's 49 checksums (1568 bytes of hex text) that is not byte-equal to ours."
  @spec first_difference([checksum()], binary()) ::
          :none | {index :: non_neg_integer(), table :: String.t(), ours :: binary(), theirs :: binary()}
  def first_difference(ours, <<theirs::binary-size(1568)>>) do
    pieces = for <<piece::binary-size(32) <- theirs>>, do: piece

    ours
    |> Enum.zip(pieces)
    |> Enum.with_index()
    |> Enum.find_value(:none, fn {{{table, hash}, piece}, index} ->
      if hash != piece, do: {index, table, hash, piece}
    end)
  end
end
