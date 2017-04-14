defmodule SocksServer.TCP do
  @moduledoc """
  A Socks5 server.

  Currently only implements:

  socks5 with no auth, ipv4 and hostname

  ## Examples

      $ mix run --no-halt
      $ # resolve hostname from local
      $ curl -v --proxy 'socks5://localhost' google.com
      $ # resolve hostname from remote
      $ curl -v --proxy 'socks5h://localhost' google.com

  """

  require Logger

  @listen_options [:binary, packet: 0, active: false, reuseaddr: true]
  @connect_options [:binary, packet: 0, active: false]

  @doc """
  Start the server from giving `port`.
  """
  def listen(port) do
    {:ok, socket} = :gen_tcp.listen(port, @listen_options)
    Logger.info "Listening connections on port #{port}"
    loop_acceptor(socket)
  end

  # Accept a new client from a listening socket
  defp loop_acceptor(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    # Logger.debug "Accept client: #{inspect(client)}"

    {:ok, pid} = Task.Supervisor.start_child(SocksServer.TaskSupervisor, fn -> socks5(client) end)
    :gen_tcp.controlling_process(client, pid)

    loop_acceptor(socket)
  end

  # Start the socks5 process: Handshake -> Connect -> Forwarding
  defp socks5(client) do
    client
    |> handshake()
    |> connect(client)
    |> forwarding(client)
  end

  # Handshake for correct socks5 client
  defp handshake(client) do
    # Logger.debug "Start handshake: #{inspect(client)}"
    case :gen_tcp.recv(client, 0) do
      {:ok, << 5, nmethod :: integer-size(8), methods :: bytes-size(nmethod) >>} ->
        # Only support no auth: 0
        true = methods |> to_charlist |> Enum.member?(0)
        :gen_tcp.send(client, << 5, 0 >>)
      _ ->
        exit(:shutdown)
    end
  end

  # Connect to the target which request by the client
  defp connect(:ok, client) do
    client
    |> :gen_tcp.recv(4)
    |> get_target_address(client)
    |> connect_target(client)
  end

  # Forward packets between two sockets
  defp forwarding(target, client) do
    # Forward afterward in a separate process
    {:ok, afterward_pid} = Task.Supervisor.start_child(SocksServer.TaskSupervisor, fn -> forward(client, target) end)
    :gen_tcp.controlling_process(client, afterward_pid)

    # Forward backward in a separate process
    {:ok, backward_pid} = Task.Supervisor.start_child(SocksServer.TaskSupervisor, fn -> forward(target, client) end)
    :gen_tcp.controlling_process(target, backward_pid)
  end

  # client wants to connect an ipv4 address
  # curl -v --proxy 'socks5://localhost' google.com
  defp get_target_address({:ok, << 5, 1, 0, 1 >>}, client) do
    case :gen_tcp.recv(client, 6) do
      {:ok, << a, b, c, d, port :: size(16) >>} -> {:ok, {a, b, c, d}, port}
      _ -> exit(:shutdown)
    end
  end
  # client wants to connect a hostname
  # curl -v --proxy 'socks5h://localhost' google.com
  defp get_target_address({:ok, << 5, 1, 0, 3 >>}, client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, << length :: integer-size(8), hostname :: bytes-size(length), port :: size(16) >>} ->
        {:ok, to_charlist(hostname), port}
      _ -> exit(:shutdown)
    end
  end

  # client wants to connect a hostname
  defp get_target_address({:ok, << 5, 1, 0, 4 >>}, _client) do
    Logger.error("IPv6 not support")
    exit(:shutdown)
  end

  defp connect_target({:ok, address, port}, client) do
    case :gen_tcp.connect(address, port, @connect_options) do
      {:ok, target} ->
        reply_connected(client)
        target
      {:error, reason} ->
        reply_connect_error(reason, client)
    end
  end

  defp reply_connected(client) do
    :gen_tcp.send(client, << 5, 0, 0, 1, 0, 0, 0, 0, 0 :: size(16) >>)
  end

  defp reply_connect_error(reason, client) do
    flag = reason_to_flag(reason)
    :gen_tcp.send(client, << 5, flag, 0, 1, 0, 0, 0, 0, 0 :: size(16) >>)
    exit(:shutdown)
  end

  defp reason_to_flag(:nxdomain), do: 4
  defp reason_to_flag(:econnrefused), do: 5

  # Forward data between sockets
  defp forward(from, to) do
    # Logger.debug("Forward #{inspect(from)} to #{inspect(to)}")
    with {:ok, data} <- :gen_tcp.recv(from, 0),
         :ok <- :gen_tcp.send(to, data) do
      forward(from, to)
    else
      _ ->
        :gen_tcp.close(from)
        :gen_tcp.close(to)
    end
  end
end
