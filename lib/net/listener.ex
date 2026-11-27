defmodule Net.Listener do
  @moduledoc """
  The client listener of a part: a Thousand Island listener whose connections run `Net.Connection`. `part` is the
  label of the server log. Once the socket is bound it logs the address; a port that cannot be bound prints one line
  on standard error and the start fails.
  """

  require Logger

  @doc "Child spec of a listener on `port` for the packet handler module `handler`."
  @spec child_spec({String.t(), module(), :inet.port_number(), Settings.t()}) :: Supervisor.child_spec()
  def child_spec(arg), do: %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [arg]}, type: :supervisor}

  @spec start_link({String.t(), module(), :inet.port_number(), Settings.t()}) :: Supervisor.on_start()
  def start_link({part, handler, port, settings}) do
    options = [
      port: port,
      handler_module: Net.Connection,
      handler_options: %{handler: handler, limits: settings.connection, settings: settings, part: part},
      # Thousand Island's own idle timeout (60 s by default) would cut in before our heartbeat.
      read_timeout: :infinity,
      # A send blocks only above the high watermark; keep it above the limit so Net.Connection sees the queue first.
      transport_options: [
        high_watermark: 2 * settings.connection.max_unsent_bytes,
        low_watermark: settings.connection.max_unsent_bytes
      ]
    ]

    case ThousandIsland.start_link(options) do
      {:ok, pid} ->
        {:ok, {address, bound}} = ThousandIsland.listener_info(pid)
        Logger.info("#{part}: listening on #{:inet.ntoa(address)}:#{bound}")
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, :listener, reason}}} = error when is_atom(reason) ->
        IO.puts(
          :stderr,
          "#{part}: cannot listen on port #{port}: #{:inet.format_error(reason)}. The node does not start."
        )

        error

      error ->
        error
    end
  end
end
