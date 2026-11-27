defmodule HoldfastEx.SSETest do
  @moduledoc "The event stream of spec §6, and ADR 0013's missed-event detection."
  use HoldfastEx.Test.DBCase, async: false

  import HoldfastEx.Test.HTTP

  alias HoldfastEx.PublicView
  alias HoldfastEx.Web.SSE

  @moduletag capture_log: true

  setup do
    # No slow poll or heartbeat unless a test asks, so they hide nothing.
    for key <- [:sse_poll_ms, :sse_heartbeat_ms], do: put_env(key, 60_000)
    %{base: start_server()}
  end

  defp put_env(key, value) do
    old = Application.fetch_env!(:holdfast_ex, key)
    Application.put_env(:holdfast_ex, key, value)
    on_exit(fn -> Application.put_env(:holdfast_ex, key, old) end)
  end

  defp place(id, user, amount) do
    {:ok, %{status: :accepted}} = Auctions.place_bid(id, offer(user, amount))
  end

  # Appends an accepted bid behind the server's back, so nothing is published: a
  # lost message. Returns the accept's seq and the one of the public event before.
  defp append_unpublished(id, bid_id, amount) do
    events = EventStore.load(id)
    {view, _} = PublicView.fold(PublicView.new(id), events)

    data = [
      %Event.BidPlaced{bid_id: bid_id, user_id: bid_id, amount: amount, idempotency_key: bid_id},
      %Event.HoldAuthorized{bid_id: bid_id, payment_intent_id: bid_id, amount_capturable: amount},
      %Event.BidAccepted{
        bid_id: bid_id,
        amount: amount,
        alias: "Bidder #{bid_id}",
        previous_high_bid_id: nil
      }
    ]

    {:ok, appended} =
      EventStore.append(id, view.version + 1, Enum.map(data, &%Event{data: &1}),
        ends_at: view.auction.ends_at
      )

    {List.last(appended).seq, view.last_public_seq}
  end

  # These logs name no real previous bid, so they aren't ones to check.
  @unchecked [check_logs: false]

  defp publish(id, previous, version) do
    {_, published} = PublicView.fold(PublicView.new(id), EventStore.load_public(id))
    {_, event} = Enum.find(published, fn {_, event} -> event.version == version end)

    :ok =
      Phoenix.PubSub.broadcast(
        HoldfastEx.PubSub,
        SSE.topic(id),
        {:holdfast_event, previous, event}
      )
  end

  test "a snapshot first, then each accept and the close, in order", %{base: base} do
    id = open_auction(600)
    cookie = sign_in(base, "ann")
    stream = open_stream(base, id, cookie: cookie)

    assert stream.headers["content-type"] == "text/event-stream"
    assert stream.headers["cache-control"] == "no-cache, no-transform"
    assert {%{retry: 2_000}, stream} = next_block(stream)

    assert {%{event: "snapshot", id: version, data: snapshot}, stream} = next_event(stream)
    assert snapshot["auction"]["version"] == version
    assert snapshot["you"] =~ "Bidder "
    assert snapshot["currentHigh"] == nil

    place(id, "ann", 500)
    assert {%{event: "bid.accepted", id: first, data: data}, stream} = next_event(stream)
    assert %{"type" => "bid.accepted", "version" => ^first, "amount" => 500} = data
    assert Enum.sort(Map.keys(data)) == ~w(amount at bidder type version)

    place(id, "bob", 600)
    assert {%{event: "bid.accepted", id: second, data: high}, stream} = next_event(stream)

    assert {%{event: "auction.closed", id: third, data: closed}, _} = next_event(stream)
    assert version < first and first < second and second < third

    assert closed == %{
             "type" => "auction.closed",
             "version" => third,
             "status" => "closed",
             "winner" => high["bidder"],
             "amount" => 600
           }

    # What arrived live is what the log says (spec §6).
    {_, published} = PublicView.fold(PublicView.new(id), EventStore.load_public(id))
    from_log = Enum.map(published, fn {_, event} -> JSON.decode!(JSON.encode!(event)) end)
    assert from_log == [data, high, closed]
  end

  test "Last-Event-ID resumes after it, with no snapshot", %{base: base} do
    id = open_auction()
    place(id, "ann", 500)
    place(id, "bob", 600)

    {_, [{_, first}, {_, second}]} =
      PublicView.fold(PublicView.new(id), EventStore.load_public(id))

    stream = open_stream(base, id, last_event_id: first.version)
    assert {%{event: "bid.accepted", id: resumed}, stream} = next_event(stream)
    assert resumed == second.version
    refute_event(stream)

    stream = open_stream(base, id, last_event_id: second.version)
    refute_event(stream)
    place(id, "cat", 700)
    assert {%{event: "bid.accepted", data: %{"amount" => 700}}, _} = next_event(stream)
  end

  test "404 for an auction that doesn't exist", %{base: base} do
    for id <- [Ecto.UUID.generate(), "nonsense"] do
      assert {:refused, 404, %{"error" => "not_found"}} = open_stream(base, id)
    end
  end

  @tag @unchecked
  test "a missed message is read back when the next one arrives", %{base: base} do
    id = open_auction()
    stream = open_stream(base, id)
    assert {%{event: "snapshot"}, stream} = next_event(stream)

    {lost, _} = append_unpublished(id, "x1", 500)
    {next, previous} = append_unpublished(id, "x2", 600)
    assert previous == lost
    publish(id, previous, next)

    assert {%{id: ^lost}, stream} = next_event(stream)
    assert {%{id: ^next}, stream} = next_event(stream)

    # A repeat of what it has is dropped.
    publish(id, previous, next)
    publish(id, 0, lost)
    refute_event(stream)
  end

  @tag @unchecked
  test "a lost last message is found by the slow poll", %{base: base} do
    put_env(:sse_poll_ms, 50)
    id = open_auction()
    stream = open_stream(base, id)
    assert {%{event: "snapshot"}, stream} = next_event(stream)

    {lost, _} = append_unpublished(id, "x1", 500)

    assert {%{id: ^lost}, stream} = next_event(stream)
    refute_event(stream)
  end

  @tag @unchecked
  test "an event the node's copy hasn't got yet is read after the snapshot", %{base: base} do
    id = open_auction()
    server(id)
    {behind, _} = append_unpublished(id, "x1", 500)

    stream = open_stream(base, id)

    assert {%{event: "snapshot", id: version}, stream} = next_event(stream)
    assert version < behind
    assert {%{event: "bid.accepted", id: ^behind}, _} = next_event(stream)
  end

  test "comment lines keep an idle stream open", %{base: base} do
    put_env(:sse_heartbeat_ms, 30)
    stream = open_stream(base, open_auction())
    assert {%{event: "snapshot"}, stream} = next_event(stream)

    assert {%{comment: "keep-alive"}, stream} = next_block(stream)
    assert {%{comment: "keep-alive"}, _} = next_block(stream)
  end
end
