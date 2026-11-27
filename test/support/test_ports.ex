defmodule TestPorts do
  @moduledoc """
  Client ports for tests, taken from the operating system (`docs/technical/testing.md`): no test listens on or
  connects to a fixed port, so another program on 9010 cannot break the suite.
  """

  @type app :: %{login: :inet.port_number(), wm: :inet.port_number(), zone: :inet.port_number()}

  @doc """
  `count` distinct ports that are free now. Each is bound on all addresses with port 0 and read back, then
  released; a port where something still answers on `127.0.0.1` (a program bound to the loopback address only,
  which Windows lets coexist with a bind on all addresses) is dropped and another one taken.
  """
  @spec free(pos_integer()) :: [:inet.port_number()]
  def free(count), do: free(count, [])

  defp free(count, taken) when length(taken) == count, do: taken

  defp free(count, taken) do
    sockets = for _ <- 1..(count - length(taken)), do: elem(:gen_tcp.listen(0, []), 1)
    ports = Enum.map(sockets, &elem(:inet.port(&1), 1))
    Enum.each(sockets, &:gen_tcp.close/1)
    free(count, taken ++ Enum.filter(ports, &(&1 not in taken and refused?(&1))))
  end

  defp refused?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _reason} ->
        true
    end
  end

  @doc "Chooses the ports of the application `test_helper.exs` starts; once, before it writes the settings file."
  @spec choose_app() :: app()
  def choose_app do
    [login, wm, zone] = free(3)
    ports = %{login: login, wm: wm, zone: zone}
    :persistent_term.put(__MODULE__, ports)
    ports
  end

  @doc "The client ports of the application of the test VM."
  @spec app() :: app()
  def app, do: :persistent_term.get(__MODULE__)

  @doc "`{host, port}` of a part of the application of the test VM."
  @spec endpoint(:login | :wm | :zone) :: {charlist(), :inet.port_number()}
  def endpoint(part), do: {~c"127.0.0.1", Map.fetch!(app(), part)}
end
