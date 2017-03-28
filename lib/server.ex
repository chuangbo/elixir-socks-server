defmodule Socks.Server do
  @moduledoc """
  A Socks5 server.

  Currently only implements:

  socks5 with no auth, ipv4 and hostname

  ## Examples

      $ mix run -e Socks.Server.start
      $ # resolve hostname from local
      $ curl -v --proxy 'socks5://localhost' google.com
      $ # resolve hostname from remote
      $ curl -v --proxy 'socks5h://localhost' google.com

  """

  require Logger

  @listen_options [:binary, packet: 0, active: false, reuseaddr: true]
  @connect_options [:binary, packet: 0, active: false]

  @doc """
  Start the server from giving port.
  """
  def start(port) when is_integer(port) do
    # :observer.start
    {:ok, server} = :gen_tcp.listen(port, @listen_options)
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
    {:ok, client} = :gen_tcp.accept(server)
    Logger.debug "Accept client: #{inspect(client)}"

    Task.start fn -> socks5(client) end

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
            :gen_tcp.close(client)
        end
      _ = error ->
        Logger.error "Handshake Error: #{inspect(error)}"
        :gen_tcp.close(client)
    end
  end

  # Handshake for correct socks5 client
  defp handshake(client) do
    # Logger.debug "Start handshake: #{inspect(client)}"
    case :gen_tcp.recv(client, 0) do
      {:ok, << 5, nmethod :: integer-size(8), methods :: bytes-size(nmethod) >>} ->
        # Only support no auth: 0
        true = methods |> to_charlist |> Enum.member?(0)
        :gen_tcp.send(client, << 5, 0 >>)
      _ = error -> error
    end
  end

  # Connect to the target which request by the client
  defp connect(client) do
    case :gen_tcp.recv(client, 4) do
      # ipv4
      {:ok, << 5, 1, 0, 1 >>} -> connect_ipv4(client)
      # domainname
      {:ok, << 5, 1, 0, 3 >>} -> connect_hostname_port(client)
      # ipv6
      {:ok, << 5, 1, 0, 4 >>} -> {:error, :notsupport}
      _ = error -> error
    end
  end

  # Connect to ipv4 target
  defp connect_ipv4(client) do
    case :gen_tcp.recv(client, 6) do
      {:ok, << a, b, c, d, port :: size(16) >>} ->
        address = "#{a}.#{b}.#{c}.#{d}"
        Logger.debug "Target: #{inspect(client)} #{address}:#{port}"
        case :gen_tcp.connect({a, b, c, d}, port, @connect_options) do
          {:ok, target} ->
            :gen_tcp.send(client, << 5, 0, 0, 1, a, b, c, d, port :: size(16) >>)
            {:ok, target}
          {:error, :econnrefused} = error ->
            :gen_tcp.send(client, << 5, 5, 0, 1, a, b, c, d, port :: size(16) >>)
            error
        end
      _ = error -> error
    end
  end

  # Connect to hostname, port target
  defp connect_hostname_port(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, << length :: integer-size(8), hostname :: bytes-size(length), port :: size(16) >>} ->
        Logger.debug "Target: #{inspect(client)} #{hostname}:#{port}"
        case :gen_tcp.connect(to_charlist(hostname), port, @connect_options) do
          {:ok, target} ->
            :gen_tcp.send(client, << 5, 0, 0, 3, length, hostname :: binary, port :: size(16) >>)
            {:ok, target}
          {:error, :econnrefused} = error ->
            :gen_tcp.send(client, << 5, 5, 0, 3, length, hostname :: binary, port :: size(16) >>)
            error
        end
      _ = error -> error
    end
  end

  # Forward data between sockets
  defp forward(from, to) do
    # Logger.debug "Forward: #{inspect(from)} -> #{inspect(to)}"
    case :gen_tcp.recv(from, 0) do
      {:ok, data} when is_binary(data) ->
        # Logger.debug "Received: #{inspect(data)} #{inspect(from)} forward to #{inspect(to)}"
        case :gen_tcp.send(to, data) do
          :ok -> forward(from, to)
          {:error, :closed} -> :ok
          _ = error ->
            Logger.error "Forward Send Error: #{inspect(error)}"
            error
        end
      {:error, :closed} -> :ok
      _ = error ->
        Logger.error "Forward Receive Error: #{inspect(error)}"
        error
    end
  end
end
