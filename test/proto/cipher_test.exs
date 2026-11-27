defmodule Proto.CipherTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Proto.Cipher

  test "table" do
    assert byte_size(Cipher.table()) == 499
    assert Base.encode16(:erlang.md5(Cipher.table()), case: :lower) == "ef5e3dd0481bdedada386a8ed08f4784"
  end

  test "keystream and wrap" do
    assert Cipher.crypt(Cipher.new(0), <<0, 0, 0, 0>>) == {<<0x07, 0x59, 0x69, 0x4A>>, 4}
    assert Cipher.crypt(Cipher.new(498), <<0, 0>>) == {<<0xEB, 0x07>>, 1}
  end

  test "new" do
    assert Cipher.new(499) == 0
    assert Cipher.new(363) == 363
    assert Cipher.new(1000) == 2
  end

  property "state carries over, crypt is an involution" do
    check all seed <- StreamData.integer(0..0xFFFF), a <- StreamData.binary(), b <- StreamData.binary() do
      {whole, end_idx} = Cipher.crypt(Cipher.new(seed), a <> b)
      {ca, mid} = Cipher.crypt(Cipher.new(seed), a)
      assert {ca <> elem(Cipher.crypt(mid, b), 0), elem(Cipher.crypt(mid, b), 1)} == {whole, end_idx}
      assert {a <> b, end_idx} == Cipher.crypt(Cipher.new(seed), whole)
    end
  end
end
