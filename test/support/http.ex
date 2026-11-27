defmodule HoldfastEx.Test.HTTP do
  @moduledoc """
  A client for the contract tests, against a real server on a free port: OTP's
  `:httpc` for requests, a socket for event streams.
  """

  import ExUnit.Assertions

  @origin "http://localhost:3000"

  def origin, do: @origin

  @doc "Starts the server under the test, and returns its base URL."
  def start_server do
    server =
      ExUnit.Callbacks.start_supervised!({HoldfastEx.Web, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  One request. Options: `:cookie`, `:headers`, `:body` (a term sent as JSON, or
  `{:raw, binary}`), `:origin` (sent on anything but GET; `nil` for none).
  Returns `%{status, headers, body, json}`.
  """
  def request(base, method, path, opts \\ []) do
    headers = request_headers(method, opts)
    url = String.to_charlist(base <> path)

    request =
      if method == :post,
        do: {url, headers, ~c"application/json", encode(opts[:body])},
        else: {url, headers}

    {:ok, {{_, status, _}, response_headers, body}} =
      :httpc.request(method, request, [autoredirect: false], body_format: :binary)

    headers = Map.new(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    json =
      if String.starts_with?(headers["content-type"] || "", "application/json") and body != "",
        do: JSON.decode!(body)

    %{status: status, headers: headers, body: body, json: json}
  end

  defp request_headers(method, opts) do
    origin = Keyword.get(opts, :origin, if(method not in [:get, :head], do: @origin))

    [origin && {"origin", origin}, opts[:cookie] && {"cookie", opts[:cookie]}]
    |> Enum.filter(& &1)
    |> Enum.concat(Keyword.get(opts, :headers, []))
    |> charlists()
  end

  defp encode(nil), do: ""
  defp encode({:raw, raw}), do: raw
  defp encode(term), do: JSON.encode!(term)

  defp charlists(headers),
    do: Enum.map(headers, fn {k, v} -> {String.to_charlist(k), :binary.bin_to_list(v)} end)

  @doc "Signs a login in and returns the `cookie` header to send."
  def sign_in(base, login) do
    response = request(base, :post, "/api/auth/dev", body: %{login: login})
    assert response.status == 204
    [cookie | _] = String.split(response.headers["set-cookie"], ";")
    cookie
  end

  def bid(base, auction_id, cookie, amount, key) do
    request(base, :post, "/api/auctions/#{auction_id}/bids",
      cookie: cookie,
      headers: [{"idempotency-key", key}],
      body: %{amount: amount}
    )
  end

  # -- server-sent events ----------------------------------------------------
  # Read off a plain socket: OTP's client now and then lost the first chunk of a
  # stream, which a running node never did.

  @doc "Opens an event stream. Returns it, or the status of a refusal."
  def open_stream(base, auction_id, opts \\ []) do
    %URI{host: host, port: port} = URI.parse(base)
    {:ok, address} = :inet.parse_address(String.to_charlist(host))
    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw])

    headers =
      [
        opts[:cookie] && "cookie: #{opts[:cookie]}\r\n",
        opts[:last_event_id] && "last-event-id: #{opts[:last_event_id]}\r\n"
      ]
      |> Enum.filter(& &1)

    :ok =
      :gen_tcp.send(socket, [
        "GET /api/auctions/#{auction_id}/events HTTP/1.1\r\nhost: #{host}\r\n",
        headers,
        "\r\n"
      ])

    {head, rest} = read_head(socket, "")
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {String.downcase(name), value}
      end)

    case String.to_integer(status) do
      200 ->
        %{socket: socket, raw: rest, buffer: "", headers: headers}

      status ->
        length = String.to_integer(headers["content-length"])
        {:refused, status, JSON.decode!(read_exactly(socket, rest, length))}
    end
  end

  defp read_head(socket, data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [head, rest] -> {head, rest}
      [_] -> read_head(socket, data <> recv!(socket))
    end
  end

  defp read_exactly(_socket, data, length) when byte_size(data) >= length, do: data

  defp read_exactly(socket, data, length),
    do: read_exactly(socket, data <> recv!(socket), length)

  defp recv!(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    data
  end

  @doc """
  The next block of the stream, as a map of its fields (`data` decoded), and the
  stream after it. A comment is `%{comment: text}`. nil if none arrives in time.
  """
  def next_block(stream, timeout \\ 2_000) do
    case String.split(stream.buffer, "\n\n", parts: 2) do
      [block, rest] ->
        {parse(block), %{stream | buffer: rest}}

      [_partial] ->
        read_more(stream, timeout)
    end
  end

  defp read_more(stream, timeout) do
    case dechunk(stream.raw, "") do
      {"", raw} ->
        receive_more(%{stream | raw: raw}, timeout)

      {data, raw} ->
        next_block(%{stream | raw: raw, buffer: stream.buffer <> data}, timeout)
    end
  end

  defp receive_more(stream, timeout) do
    case :gen_tcp.recv(stream.socket, 0, timeout) do
      {:ok, data} -> next_block(%{stream | raw: stream.raw <> data}, timeout)
      {:error, :timeout} -> {nil, stream}
    end
  end

  # Takes the whole chunks of a chunked body off the front.
  defp dechunk(raw, taken) do
    with [size, rest] <- String.split(raw, "\r\n", parts: 2),
         {size, ""} when size > 0 <- Integer.parse(size, 16),
         <<data::binary-size(^size), "\r\n", rest::binary>> <- rest do
      dechunk(rest, taken <> data)
    else
      _ -> {taken, raw}
    end
  end

  @doc "The next event, skipping `retry` and comments."
  def next_event(stream) do
    case next_block(stream) do
      {%{event: _} = event, stream} -> {event, stream}
      {nil, _} -> flunk("no event arrived")
      {_other, stream} -> next_event(stream)
    end
  end

  @doc "Fails if any event arrives within `ms`."
  def refute_event(stream, ms \\ 150) do
    case next_block(stream, ms) do
      {nil, _} -> :ok
      {%{event: _} = event, _} -> flunk("unexpected event: #{inspect(event)}")
      {_other, stream} -> refute_event(stream, ms)
    end
  end

  defp parse(":" <> comment), do: %{comment: String.trim(comment)}

  defp parse(block) do
    block
    |> String.split("\n")
    |> Map.new(fn line ->
      case String.split(line, ": ", parts: 2) do
        ["event", event] -> {:event, event}
        ["id", id] -> {:id, String.to_integer(id)}
        ["data", data] -> {:data, JSON.decode!(data)}
        ["retry", ms] -> {:retry, String.to_integer(ms)}
      end
    end)
  end
end
