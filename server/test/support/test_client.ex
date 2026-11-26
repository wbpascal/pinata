defmodule TestClient do
  @moduledoc """
  A TCP-only test client for the client-facing protocol (see `docs/technical/testing.md`).

  It frames, encrypts and decodes like the 2016 client. The cipher starts when the seed packet `0x0807` is received.
  A body is the opcode (u16 LE) followed by the payload.
  """

  import ExUnit.Assertions

  @enforce_keys [:socket, :cipher, :buffer]
  defstruct [:socket, :cipher, :buffer]

  @type t :: %__MODULE__{socket: :gen_tcp.socket(), cipher: Proto.Cipher.t() | nil, buffer: binary()}

  @doc "Opens a connection; raises when it fails. Reads nothing."
  @spec connect(charlist(), :inet.port_number()) :: t()
  def connect(host, port) do
    {:ok, client} = try_connect(host, port)
    client
  end

  @doc "Opens a connection; returns the error when it fails (the load run counts them). Reads nothing."
  @spec try_connect(charlist(), :inet.port_number()) :: {:ok, t()} | {:error, term()}
  def try_connect(host, port) do
    with {:ok, socket} <- :gen_tcp.connect(host, port, [:binary, active: false]) do
      {:ok, %__MODULE__{socket: socket, cipher: nil, buffer: <<>>}}
    end
  end

  @doc "Receives the next body (opcode and payload) without decoding it."
  @spec recv_raw(t(), timeout()) :: {:ok, binary(), t()} | {:error, :timeout | :closed}
  def recv_raw(%__MODULE__{socket: socket, buffer: buffer} = client, timeout \\ 1000) do
    case Proto.Framing.split(buffer) do
      {:ok, body, rest} ->
        {:ok, body, started(%{client | buffer: rest}, body)}

      :more ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} -> recv_raw(%{client | buffer: buffer <> data}, timeout)
          {:error, :timeout} -> {:error, :timeout}
          {:error, _reason} -> {:error, :closed}
        end
    end
  end

  @doc """
  Like `recv_raw/2`, but a timeout returns the client with the bytes read so far, so that a client that polls with
  short timeouts never loses a partial frame.
  """
  @spec poll(t(), timeout()) :: {:ok, binary(), t()} | {:timeout, t()} | {:error, :closed}
  def poll(%__MODULE__{socket: socket, buffer: buffer} = client, timeout) do
    case Proto.Framing.split(buffer) do
      {:ok, body, rest} ->
        {:ok, body, started(%{client | buffer: rest}, body)}

      :more ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} -> poll(%{client | buffer: buffer <> data}, 0)
          {:error, :timeout} -> {:timeout, client}
          {:error, _reason} -> {:error, :closed}
        end
    end
  end

  defp started(%__MODULE__{cipher: nil} = client, <<0x07, 0x08, seed::little-16>>),
    do: %{client | cipher: Proto.Cipher.new(seed)}

  defp started(client, _body), do: client

  @doc "Receives and decodes the next packet."
  @spec recv(t(), timeout()) ::
          {:ok, struct(), t()} | {:error, :timeout | :closed | :unknown_opcode | :bad_size}
  def recv(client, timeout \\ 1000) do
    with {:ok, body, client} <- recv_raw(client, timeout),
         {:ok, packet} <- Proto.decode(body) do
      {:ok, packet, client}
    end
  end

  @doc "Sends a body (opcode and payload). Raises before the seed packet was received."
  @spec send_raw(t(), binary()) :: {:ok, t()} | {:error, :closed}
  def send_raw(%__MODULE__{cipher: nil}, _body), do: raise(ArgumentError, "no seed received yet")

  def send_raw(%__MODULE__{socket: socket, cipher: cipher} = client, body) do
    {encrypted, cipher} = Proto.Cipher.crypt(cipher, body)
    {:ok, frame} = Proto.Framing.frame(encrypted)

    case :gen_tcp.send(socket, frame) do
      :ok -> {:ok, %{client | cipher: cipher}}
      {:error, _reason} -> {:error, :closed}
    end
  end

  @doc "Encodes and sends a packet."
  @spec send_packet(t(), struct()) :: {:ok, t()} | {:error, :closed}
  def send_packet(client, packet), do: send_raw(client, Proto.encode(packet))

  @doc "Asserts that the next packet is exactly `packet`; returns the client."
  @spec expect(t(), struct(), timeout()) :: t()
  def expect(client, packet, timeout \\ 1000) do
    assert {:ok, ^packet, client} = recv(client, timeout)
    client
  end

  @doc "Closes the connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)
end
