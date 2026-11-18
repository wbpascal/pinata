defmodule Net.Listener do
  @moduledoc "The client listener of a part: a Thousand Island listener whose connections run `Net.Connection`."

  @doc "Child spec of a listener on `port` for the packet handler module `handler`."
  @spec child_spec({module(), :inet.port_number(), Settings.t()}) :: Supervisor.child_spec()
  def child_spec({handler, port, settings}) do
    ThousandIsland.child_spec(
      port: port,
      handler_module: Net.Connection,
      handler_options: %{handler: handler, limits: settings.connection},
      # Thousand Island's own idle timeout (60 s by default) would cut in before our heartbeat.
      read_timeout: :infinity,
      # A send blocks only above the high watermark; keep it above the limit so Net.Connection sees the queue first.
      transport_options: [
        high_watermark: 2 * settings.connection.max_unsent_bytes,
        low_watermark: settings.connection.max_unsent_bytes
      ]
    )
  end
end
