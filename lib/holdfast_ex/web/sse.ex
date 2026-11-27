defmodule HoldfastEx.Web.SSE do
  @moduledoc """
  One SSE connection (spec §6, ADRs 0009, 0013): a snapshot, or a resume from
  `Last-Event-ID`, then public events in order, each once.

  The connection's own process runs the loop: it subscribes to the auction's topic
  and waits on its mailbox. The log is the truth. A published event only saves a
  read, and a missed one is read back.
  """

  import Plug.Conn

  alias HoldfastEx.Alias
  alias HoldfastEx.Auctions
  alias HoldfastEx.EventStore
  alias HoldfastEx.PublicView

  @retry_ms 2_000

  @doc "The PubSub topic of an auction's public events."
  def topic(auction_id), do: "auction:" <> auction_id

  def stream(conn, auction_id, user) do
    # Subscribe before reading, so nothing published during the reads is lost.
    :ok = Phoenix.PubSub.subscribe(HoldfastEx.PubSub, topic(auction_id))

    try do
      with {:ok, view} <- Auctions.view(auction_id), do: {:ok, open(conn, view, user)}
    after
      # The connection's process can outlive this request.
      Phoenix.PubSub.unsubscribe(HoldfastEx.PubSub, topic(auction_id))
    end
  end

  defp open(conn, view, user) do
    resume = last_event_id(conn)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache, no-transform")
      # Proxies must not buffer the stream.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    first =
      if resume do
        ["retry: #{@retry_ms}\n\n"]
      else
        you = user && Alias.of(view.id, user.id)
        snapshot = PublicView.snapshot(view, DateTime.utc_now(), you)
        ["retry: #{@retry_ms}\n\n", frame("snapshot", view.version, snapshot)]
      end

    heartbeat = tick(:heartbeat)
    poll = tick(:poll)

    stream = %{conn: conn, id: view.id, last: resume || view.version}

    try do
      # The node's copy may be behind the log, so read once more.
      with {:ok, stream} <- write(stream, first),
           {:ok, stream} <- catch_up(stream) do
        loop(stream).conn
      else
        {:closed, stream} -> stream.conn
      end
    after
      _ = Process.cancel_timer(heartbeat)
      _ = Process.cancel_timer(poll)
    end
  end

  # Only our own messages are taken: the server's must stay in the mailbox.
  defp loop(stream) do
    result =
      receive do
        {:holdfast_event, previous, event} ->
          deliver(stream, previous, event)

        {__MODULE__, :heartbeat} ->
          _ = tick(:heartbeat)
          write(stream, ": keep-alive\n\n")

        # For a lost message that nothing follows, such as the last one.
        {__MODULE__, :poll} ->
          _ = tick(:poll)
          catch_up(stream)
      end

    case result do
      {:ok, stream} -> loop(stream)
      {:closed, stream} -> stream
    end
  end

  # ADR 0013: a duplicate is dropped, and a previous public seq past what we have
  # means a message was missed.
  defp deliver(%{last: last} = stream, previous, %{version: version} = event) do
    cond do
      version <= last -> {:ok, stream}
      previous > last -> catch_up(stream)
      true -> send_event(stream, event)
    end
  end

  defp catch_up(stream) do
    events = EventStore.load_public(stream.id)
    {_view, published} = PublicView.fold(PublicView.new(stream.id), events)

    published
    |> Enum.map(fn {_previous, event} -> event end)
    |> Enum.filter(&(&1.version > stream.last))
    |> Enum.reduce_while({:ok, stream}, &send_next/2)
  end

  defp send_next(event, {:ok, stream}) do
    case send_event(stream, event) do
      {:ok, stream} -> {:cont, {:ok, stream}}
      closed -> {:halt, closed}
    end
  end

  defp send_event(stream, %{type: type, version: version} = event) do
    with {:ok, stream} <- write(stream, frame(type, version, event)),
         do: {:ok, %{stream | last: version}}
  end

  defp write(stream, data) do
    case chunk(stream.conn, data) do
      {:ok, conn} -> {:ok, %{stream | conn: conn}}
      {:error, _closed} -> {:closed, stream}
    end
  end

  defp frame(event, id, data),
    do: [
      "event: ",
      event,
      "\nid: ",
      Integer.to_string(id),
      "\ndata: ",
      JSON.encode!(data),
      "\n\n"
    ]

  defp last_event_id(conn) do
    with [value] <- get_req_header(conn, "last-event-id"),
         {id, ""} when id >= 0 <- Integer.parse(value) do
      id
    else
      _ -> nil
    end
  end

  defp tick(name) do
    key = if name == :heartbeat, do: :sse_heartbeat_ms, else: :sse_poll_ms
    wait = Application.fetch_env!(:holdfast_ex, key)
    Process.send_after(self(), {__MODULE__, name}, wait)
  end
end
