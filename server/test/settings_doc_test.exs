defmodule Settings.DocTest do
  use ExUnit.Case, async: true

  @page Path.expand("../docs/user/settings.md", __DIR__)

  test "the page is current" do
    assert File.read!(@page) == Settings.Doc.render(),
           ~s|stale: run mix run --no-start -e 'File.write!("docs/user/settings.md", Settings.Doc.render())'|
  end

  test "every key is listed" do
    page = File.read!(@page)

    for key <- ~w(data_dir public_host client_version_key login.port login.auto_create_accounts world_manager.port
                  zone.port database.url cluster.nodes data.strict_references) ++ ["[[world]] number", "[[world]] name"] do
      assert page =~ "`#{key}`"
    end
  end
end
