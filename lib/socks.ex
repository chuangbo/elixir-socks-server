defmodule Socks do
  @moduledoc """
  A Socks5 server.

  Currently only implements:

  socks5 with no auth, ipv4 and hostname

  ## Examples

      $ mix run -e Socks.start
      $ # resolve hostname from local
      $ curl -v --proxy 'socks5://localhost' google.com
      $ # resolve hostname from remote
      $ curl -v --proxy 'socks5h://localhost' google.com

  """

  require Logger

  @doc """
  Start the server from giving port.
  """
  def start(port) when is_integer(port) do
    # :observer.start
    server = Socket.TCP.listen! port
    Logger.info "Listening on #{port}"
    accept_loop server
  end

  @doc """
  Start the server from default port 1080
  """
  def start do
    port = Application.get_env(:socks, :port)
    start(port)
  end

  # Accept a new client from a listening socket
  defp accept_loop(server) do
    client = server |> Socket.TCP.accept!
    Logger.debug "Accept client: #{inspect(client)}"

    {:ok, _} = Task.start fn -> socks5(client) end

    accept_loop(server)
  end

  # Start the socks5 process: Handshake -> Connect -> Forwarding
  defp socks5(client) do
    case handshake(client) do
      :ok ->
        Logger.debug "Handshake success #{inspect(client)}"
        case connect(client) do
          {:ok, target} ->
            Logger.debug "Connected target #{inspect(target)}"
            # Forward afterward in a separate process
            Task.start_link fn -> forward(client, target) end
            # Forward backward
            # FIXME: it's not in a separate process because I don't know how to do it
            # Put both forwarding in processes will cause self process finish, which
            # cause target socket closed
            forward(target, client)
          _ = error ->
            Logger.error "Connect Error: #{inspect(error)}"
            client |> Socket.close
        end
      _ = error ->
        Logger.error "Handshake Error: #{inspect(error)}"
        client |> Socket.close
    end
  end

  # Handshake for correct socks5 client
  defp handshake(client) do
    # Logger.debug "Start handshake: #{inspect(client)}"
    case client |> Socket.Stream.recv(2) do
      {:ok, << 5, nmethod >>} ->
        case client |> Socket.Stream.recv(nmethod) do
          {:ok, << methods :: binary >>} ->
            # Only support no auth: 0
            true = methods |> to_charlist |> Enum.member?(0)
            client |> Socket.Stream.send!(<< 5, 0 >>)
          _ = error -> error
        end
      _ -> :error
    end
  end

  # Connect to the target which request by the client
  defp connect(client) do
    case client |> Socket.Stream.recv(4) do
      # ipv4
      {:ok, << 5, 1, 0, 1 >>} -> connect_ipv4(client)
      # domainname
      {:ok, << 5, 1, 0, 3 >>} -> connect_hostname_port(client)
      # ipv6
      {:ok, << 5, 1, 0, 4 >>} -> {:error, :notsupport}
      _ -> :error
    end
  end

  # Connect to ipv4 target
  defp connect_ipv4(client) do
    case client |> Socket.Stream.recv(6) do
      {:ok, << a, b, c, d, port :: size(16) >>} ->
        address = "#{a}.#{b}.#{c}.#{d}"
        Logger.debug "Target: #{inspect(client)} #{address}:#{port}"
        case Socket.TCP.connect(address, port) do
          {:ok, target} ->
            client |> Socket.Stream.send(<< 5, 0, 0, 1, a, b, c, d, port :: size(16) >>)
            {:ok, target}
          {:error, :econnrefused} = error ->
            client |> Socket.Stream.send(<< 5, 5, 0, 1, a, b, c, d, port :: size(16) >>)
            error
        end
    end
  end

  # Connect to hostname, port target
  defp connect_hostname_port(client) do
    case client |> Socket.Stream.recv(1) do
      {:ok, << length >>} ->
        case client |> Socket.Stream.recv(length + 2) do
          {:ok, <<hostname :: bytes-size(length), port :: size(16) >>} ->
            Logger.debug "Target: #{inspect(client)} #{hostname}:#{port}"
            case Socket.TCP.connect(hostname, port) do
              {:ok, target} ->
                client |> Socket.Stream.send(<< 5, 0, 0, 3, length >> <> hostname <> << port :: size(16) >>)
                {:ok, target}
              {:error, :econnrefused} = error ->
                client |> Socket.Stream.send(<< 5, 5, 0, 3, length >> <> hostname <> << port :: size(16) >>)
                error
            end
        end
    end
  end

  # Forward data between sockets
  defp forward(from, to) do
    # Logger.debug "Forward: #{inspect(from)} -> #{inspect(to)}"
    case from |> Socket.Stream.recv do
      {:ok, data} when is_binary(data) ->
        # Logger.debug "Received: #{inspect(data)} #{inspect(from)} forward to #{inspect(to)}"
        case to |> Socket.Stream.send(data) do
          :ok -> forward(from, to)
          _ = error ->
            Logger.error "Forward Error: #{inspect(error)}"
            error
        end
      _ -> :error
    end
  end
end
