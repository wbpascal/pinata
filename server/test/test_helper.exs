# The custom Credo checks live outside lib/ (Credo is not a production dependency).
"../credo/checks/*.ex" |> Path.expand(__DIR__) |> Path.wildcard() |> Enum.each(&Code.require_file/1)

# Under `mix check` the credo step may already have started the app, so the result is ignored.
_ = Application.ensure_all_started(:credo)

source = Path.expand("../../Files/Server/2016/9Data", __DIR__)

# Git LFS pointers are a few hundred bytes; the real ItemInfo.shn is several MB.
if not File.exists?(Path.join(source, "Shine/ItemInfo.shn")) or
     File.stat!(Path.join(source, "Shine/ItemInfo.shn")).size < 1_000_000 do
  raise "the tests need Files/Server/2016/9Data (run: git lfs pull)"
end

dir = Path.join(System.tmp_dir!(), "pinata-test-data-#{System.pid()}")
File.rm_rf!(dir)
{:ok, _report} = GameData.Import.run(source, dir)
File.write!(dir <> ".toml", "data_dir = #{inspect(dir)}\n")
System.put_env("PINATA_CONFIG", dir <> ".toml")
System.put_env("PINATA_TEST_DATA_DIR", dir)
{:ok, _started} = Application.ensure_all_started(:pinata)

ExUnit.after_suite(fn _result ->
  File.rm_rf!(dir)
  File.rm!(dir <> ".toml")
end)

ExUnit.start()
