defmodule TestPorts do
  @moduledoc """
  Free TCP ports from the operating system, so no test depends on a fixed port (docs/technical/testing.md, "Ports").

  A node reads its ports from the settings file and the schema refuses port 0, so the ports are picked here first:
  listen on port 0, read the port, close. All sockets of one call are open at the same time, so its ports differ.
  """

  @type t :: %{login: :inet.port_number(), wm: :inet.port_number(), zone: :inet.port_number()}

  @doc "`count` different free ports."
  @spec free(pos_integer()) :: [:inet.port_number()]
  def free(count) do
    sockets =
      for _ <- 1..count do
        {:ok, socket} = :gen_tcp.listen(0, [])
        socket
      end

    ports =
      Enum.map(sockets, fn socket ->
        {:ok, port} = :inet.port(socket)
        port
      end)

    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end

  @doc "Free ports for the three client listeners of one topology."
  @spec pick() :: t()
  def pick do
    [login, wm, zone] = free(3)
    %{login: login, wm: wm, zone: zone}
  end

  @doc "The three port sections of a settings file."
  @spec toml(t()) :: String.t()
  def toml(ports),
    do: "\n[login]\nport = #{ports.login}\n\n[world_manager]\nport = #{ports.wm}\n\n[zone]\nport = #{ports.zone}\n"

  @doc "Remembers the ports of the application of the test VM (`test_helper.exs` calls it once)."
  @spec put_local(t()) :: :ok
  def put_local(ports), do: :persistent_term.put(__MODULE__, ports)

  @doc "The ports of the application of the test VM."
  @spec local() :: t()
  def local, do: :persistent_term.get(__MODULE__)
end
