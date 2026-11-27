defmodule HoldfastEx.ContractTest do
  @moduledoc "The routes and status codes of spec §6, over a real socket."
  use HoldfastEx.Test.DBCase, async: false

  import HoldfastEx.Test.HTTP

  alias HoldfastEx.Snapshots
  alias HoldfastEx.Web.Router

  @moduletag capture_log: true

  @bid_keys ~w(amount auctionId createdAt id reason resolvedAt status)
  @iso ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/

  setup do
    %{base: start_server()}
  end

  defp put_env(key, value) do
    old = Application.fetch_env!(:holdfast_ex, key)
    Application.put_env(:holdfast_ex, key, value)
    on_exit(fn -> Application.put_env(:holdfast_ex, key, old) end)
  end

  defp error(response, status, code) do
    assert response.status == status
    assert %{"error" => ^code, "message" => message} = response.json
    assert is_binary(message)
  end

  describe "sign-in" do
    test "config says what the page should show", %{base: base} do
      assert request(base, :get, "/api/config").json == %{
               "githubSignIn" => false,
               "devSignIn" => true,
               "cardRequired" => false,
               "stripePublishableKey" => nil
             }
    end

    test "dev sign-in, me, and logout", %{base: base} do
      error(request(base, :get, "/api/me"), 401, "unauthenticated")

      response = request(base, :post, "/api/auth/dev", body: %{login: "Ann-1"})
      assert response.status == 204
      set_cookie = response.headers["set-cookie"]
      assert set_cookie =~ "holdfast_session="

      for attribute <- ["HttpOnly", "secure", "SameSite=Lax", "path=/", "max-age=604800"] do
        assert String.downcase(set_cookie) =~ String.downcase(attribute)
      end

      cookie = sign_in(base, "Ann-1")

      assert request(base, :get, "/api/me", cookie: cookie).json == %{
               "user" => %{"login" => "Ann-1"},
               "hasCard" => false,
               "cardRequired" => false
             }

      assert request(base, :post, "/api/auth/logout", cookie: cookie).status == 204
      error(request(base, :get, "/api/me", cookie: cookie), 401, "unauthenticated")
    end

    test "only the hash of a session is stored, and it expires", %{base: base} do
      "holdfast_session=" <> token = cookie = sign_in(base, "ann")
      {:ok, raw} = Base.url_decode64(token, padding: false)

      assert %{rows: [[stored]]} = HoldfastEx.Repo.query!("SELECT id FROM sessions")
      assert stored == :crypto.hash(:sha256, raw)

      HoldfastEx.Repo.query!("UPDATE sessions SET expires_at = now()")
      error(request(base, :get, "/api/me", cookie: cookie), 401, "unauthenticated")
    end

    test "refuses a bad login, a garbage cookie, and too many tries", %{base: base} do
      for body <- [
            %{},
            %{login: ""},
            %{login: "a b"},
            %{login: String.duplicate("a", 40)},
            %{login: 5},
            {:raw, "{"}
          ] do
        error(request(base, :post, "/api/auth/dev", body: body), 400, "bad_request")
      end

      error(request(base, :get, "/api/me", cookie: "holdfast_session=%%"), 401, "unauthenticated")

      put_env(:auth_rate_limit, {1, 60_000})
      HoldfastEx.RateLimit.reset()
      assert request(base, :post, "/api/auth/dev", body: %{login: "a"}).status == 204
      error(request(base, :post, "/api/auth/dev", body: %{login: "a"}), 429, "rate_limited")
    end

    test "has no dev route unless it is enabled", %{base: base} do
      put_env(:dev_sign_in, false)
      error(request(base, :post, "/api/auth/dev", body: %{login: "a"}), 404, "not_found")
      assert request(base, :get, "/api/config").json["devSignIn"] == false
    end

    test "changes nothing without our own origin", %{base: base} do
      id = open_auction()

      for path <- ["/api/auth/dev", "/api/auth/logout", "/api/auctions/#{id}/bids"],
          origin <- [nil, "https://elsewhere.example", "http://localhost:3001"] do
        error(request(base, :post, path, origin: origin, body: %{login: "a"}), 403, "forbidden")
      end
    end
  end

  describe "listing and snapshots" do
    test "lists live, upcoming and just ended auctions", %{base: base} do
      now = DateTime.utc_now()

      record = fn title, starts, ends ->
        params = %{
          params()
          | title: title,
            starts_at: DateTime.add(now, starts, :second),
            ends_at: DateTime.add(now, ends, :second)
        }

        {:ok, id} = Auctions.record(params, now)
        id
      end

      live = record.("live", -60, 600)
      _upcoming = record.("upcoming", 600, 1_200)
      _ended = record.("ended", -7_200, -3_600)
      _long_ago = record.("long ago", -200_000, -190_000)
      cookie = sign_in(base, "ann")
      assert bid(base, live, cookie, 700, "k").status == 201

      %{"auctions" => auctions} = request(base, :get, "/api/auctions").json

      # Latest end first. The ended one has no close event: nothing ran it.
      assert Enum.map(auctions, &{&1["title"], &1["status"], &1["currentHigh"]}) == [
               {"upcoming", "scheduled", nil},
               {"live", "open", 700},
               {"ended", "open", nil}
             ]

      assert Enum.all?(auctions, &(&1["endsAt"] =~ @iso))
      assert Enum.find(auctions, &(&1["id"] == live))["currentHigh"] == 700
    end

    test "a snapshot has the contract's shape, and your alias only if you're signed in",
         %{base: base} do
      id = open_auction()
      cookie = sign_in(base, "ann-the-bidder")
      assert bid(base, id, cookie, 500, "k1").status == 201

      signed_in = request(base, :get, "/api/auctions/#{id}", cookie: cookie)
      assert signed_in.status == 200

      assert %{
               "auction" => auction,
               "currentHigh" => high,
               "recentBids" => [high],
               "you" => "Bidder " <> _ = you
             } = signed_in.json

      assert Enum.sort(Map.keys(auction)) ==
               ~w(endsAt id minIncrement minimumNextBid startingPrice startsAt status title version)

      assert %{"id" => ^id, "status" => "open", "minimumNextBid" => 600, "version" => version} =
               auction

      assert %{"amount" => 500, "bidder" => ^you, "version" => ^version, "at" => at} = high
      assert at =~ @iso
      assert auction["startsAt"] =~ @iso

      # Never a user id or a login (spec §6).
      %{rows: [[user_id]]} = HoldfastEx.Repo.query!("SELECT id::text FROM users")
      refute signed_in.body =~ user_id
      refute signed_in.body =~ "ann-the-bidder"

      assert request(base, :get, "/api/auctions/#{id}").json["you"] == nil
      # The same person is someone else in another auction.
      other = request(base, :get, "/api/auctions/#{open_auction()}", cookie: cookie)
      refute other.json["you"] == you
    end

    test "scheduled before it opens, closed after, with no minimum", %{base: base} do
      later = %{
        params()
        | starts_at: DateTime.add(DateTime.utc_now(), 600),
          ends_at: DateTime.add(DateTime.utc_now(), 900)
      }

      {:ok, scheduled} = Auctions.create(later)
      closed = open_auction(50)
      eventually(fn -> count(closed, Event.AuctionClosed) == 1 end)

      assert %{"status" => "scheduled", "minimumNextBid" => 500} =
               request(base, :get, "/api/auctions/#{scheduled}").json["auction"]

      assert %{"status" => "closed", "minimumNextBid" => nil} =
               request(base, :get, "/api/auctions/#{closed}").json["auction"]
    end

    test "404 for an auction that doesn't exist", %{base: base} do
      for id <- [Ecto.UUID.generate(), "nonsense"] do
        error(request(base, :get, "/api/auctions/#{id}"), 404, "not_found")
      end
    end

    test "a node with no copy starts the auction's server to get one", %{base: base} do
      id = open_auction()
      server(id)
      stop_auctions()
      Snapshots.delete(id)

      assert request(base, :get, "/api/auctions/#{id}").status == 200
      assert Auctions.whereis(id)
      assert Snapshots.get(id)
    end
  end

  describe "placing a bid" do
    setup %{base: base} do
      %{id: open_auction(), ann: sign_in(base, "ann"), bob: sign_in(base, "bob")}
    end

    test "201 accepted or rejected, with the bid", %{base: base, id: id, ann: ann, bob: bob} do
      accepted = bid(base, id, ann, 500, "a")
      assert accepted.status == 201
      assert %{"bid" => bid} = accepted.json
      assert Enum.sort(Map.keys(bid)) == @bid_keys
      assert %{"auctionId" => ^id, "amount" => 500, "status" => "accepted", "reason" => nil} = bid
      assert bid["createdAt"] =~ @iso and bid["resolvedAt"] =~ @iso

      assert %{status: 201, json: %{"bid" => %{"status" => "rejected", "reason" => reason}}} =
               bid(base, id, bob, 550, "b")

      assert reason == "below_minimum"
    end

    test "a bid after the close is 201, rejected, ended", %{base: base, ann: ann} do
      id = open_auction(50)
      eventually(fn -> count(id, Event.AuctionClosed) == 1 end)

      assert %{status: 201, json: %{"bid" => %{"status" => "rejected", "reason" => "ended"}}} =
               bid(base, id, ann, 500, "late")
    end

    test "202 while pending, then the poll follows it", %{base: base, id: id, ann: ann} do
      put_env(:bid_deadline_ms, 30)
      Memory.pause()

      response = bid(base, id, ann, 500, "slow")
      assert response.status == 202
      assert %{"id" => bid_id, "status" => "pending", "resolvedAt" => nil} = response.json["bid"]

      poll = fn -> request(base, :get, "/api/bids/#{bid_id}", cookie: ann) end
      assert poll.().json["bid"]["status"] == "pending"

      Memory.release()
      eventually(fn -> poll.().json["bid"]["status"] == "accepted" end)
    end

    test "lost_race when another bid is confirmed first", %{base: base, id: id} = context do
      put_env(:bid_deadline_ms, 30)
      Memory.pause()
      %{json: %{"bid" => first}} = bid(base, id, context.ann, 500, "a")
      %{json: %{"bid" => second}} = bid(base, id, context.bob, 500, "b")
      Memory.release(second["id"])
      eventually(fn -> count(id, Event.BidAccepted) == 1 end)
      Memory.release()
      eventually(fn -> count(id, Event.BidLost) == 1 end)

      assert %{"status" => "lost_race", "reason" => "below_minimum"} =
               request(base, :get, "/api/bids/#{first["id"]}", cookie: context.ann).json["bid"]
    end

    test "a retry returns the same bid as it stands now", %{base: base, id: id} = context do
      %{json: %{"bid" => bid}} = bid(base, id, context.ann, 500, "k")
      assert bid(base, id, context.bob, 600, "k").status == 201

      retry = bid(base, id, context.ann, 500, "k")
      assert retry.status == 201
      assert %{"id" => same, "status" => "outbid"} = retry.json["bid"]
      assert same == bid["id"]
    end

    test "422 for a key reused with another amount or auction", %{base: base, id: id, ann: ann} do
      # Even if the first bid was rejected.
      assert bid(base, id, ann, 100, "k").json["bid"]["status"] == "rejected"
      error(bid(base, id, ann, 700, "k"), 422, "idempotency_conflict")
      error(bid(base, open_auction(), ann, 100, "k"), 422, "idempotency_conflict")
    end

    test "400 for a missing or bad key, or a bad body", %{base: base, id: id, ann: ann} do
      # Bad requests count against the limit too, and this sends many.
      put_env(:bid_rate_limit, {100, 60_000})
      path = "/api/auctions/#{id}/bids"
      post = fn opts -> request(base, :post, path, [cookie: ann] ++ opts) end

      error(post.(body: %{amount: 500}), 400, "bad_request")

      for key <- ["", String.duplicate("k", 101), <<0xFF>>] do
        opts = [headers: [{"idempotency-key", key}], body: %{amount: 500}]
        error(post.(opts), 400, "bad_request")
      end

      for body <- [
            %{},
            %{amount: 0},
            %{amount: -5},
            %{amount: 5.5},
            %{amount: "500"},
            %{amount: 100_000_000},
            %{amount: 500, extra: true},
            {:raw, "amount=500"},
            {:raw, "[500]"},
            {:raw, String.duplicate(" ", 2_000) <> ~s({"amount":500})}
          ] do
        error(post.(headers: [{"idempotency-key", "k"}], body: body), 400, "bad_request")
      end

      assert count(id, Event.BidPlaced) == 0
      assert bid(base, id, ann, 99_999_999, String.duplicate("k", 100)).status == 201
    end

    test "401 signed out, 404 unknown auction", %{base: base, id: id, ann: ann} do
      error(bid(base, id, "holdfast_session=nope", 500, "k"), 401, "unauthenticated")

      for unknown <- [Ecto.UUID.generate(), "nonsense"] do
        error(bid(base, unknown, ann, 500, "k"), 404, "not_found")
      end
    end

    test "429 once a bidder is over the limit", %{base: base, id: id} = context do
      put_env(:bid_rate_limit, {2, 60_000})
      assert bid(base, id, context.ann, 500, "1").status == 201
      assert bid(base, id, context.ann, 600, "2").status == 201
      error(bid(base, id, context.ann, 700, "3"), 429, "rate_limited")
      # The limit is each bidder's own.
      assert bid(base, id, context.bob, 700, "3").status == 201
    end

    test "503 when it can't find out what happened to the bid", %{base: base, id: id, ann: ann} do
      put_env(:bid_deadline_ms, 10)
      pause_at(id, :bid_received)

      error(bid(base, id, ann, 500, "stuck"), 503, "unavailable")

      assert_received {:paused, server}
      resume(server)
      # The same key is safe to send again.
      eventually(fn -> count(id, Event.BidPlaced) == 1 end)
      assert bid(base, id, ann, 500, "stuck").status == 201
      assert count(id, Event.BidPlaced) == 1
    end

    test "the poll is the bidder's own: outbid, won, 404 for others", %{base: base} = context do
      id = open_auction(400)
      %{json: %{"bid" => first}} = bid(base, id, context.ann, 500, "a")
      %{json: %{"bid" => second}} = bid(base, id, context.bob, 600, "b")
      poll = fn bid, cookie -> request(base, :get, "/api/bids/#{bid["id"]}", cookie: cookie) end

      assert poll.(second, context.bob).json["bid"]["status"] == "accepted"
      eventually(fn -> poll.(second, context.bob).json["bid"]["status"] == "won" end)
      assert poll.(first, context.ann).json["bid"]["status"] == "outbid"

      error(poll.(first, context.bob), 404, "not_found")
      error(poll.(first, nil), 401, "unauthenticated")
      error(poll.(%{"id" => Ecto.UUID.generate()}, context.ann), 404, "not_found")
      error(poll.(%{"id" => "nonsense"}, context.ann), 404, "not_found")
    end
  end

  describe "everything else" do
    test "unknown API paths are JSON 404s", %{base: base} do
      error(request(base, :get, "/api/nothing"), 404, "not_found")
      error(request(base, :get, "/api"), 404, "not_found")
      error(request(base, :post, "/api/stripe/webhook", origin: nil), 404, "not_found")
      error(request(base, :post, "/api/me/card/setup"), 404, "not_found")
      error(request(base, :post, "/anything"), 404, "not_found")
      error(request(base, :get, "/"), 404, "not_found")
    end

    test "serves the built page, and its shell for page routes", %{base: base} do
      dir = Path.join(System.tmp_dir!(), "holdfast-page-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "assets"))
      File.write!(Path.join(dir, "index.html"), "<div id=root></div>")
      File.write!(Path.join(dir, "assets/app-abc.js"), "1")
      on_exit(fn -> File.rm_rf!(dir) end)
      Application.put_env(:holdfast_ex, :web_dist, dir)
      on_exit(fn -> Application.put_env(:holdfast_ex, :web_dist, nil) end)

      for path <- ["/", "/auctions/#{Ecto.UUID.generate()}", "/index.html"] do
        response = request(base, :get, path)
        assert response.status == 200
        assert response.body == "<div id=root></div>"
        assert response.headers["cache-control"] == "no-cache"
      end

      asset = request(base, :get, "/assets/app-abc.js")
      assert asset.status == 200
      assert asset.headers["cache-control"] =~ "immutable"
      assert request(base, :head, "/").status == 200
      error(request(base, :get, "/api/nothing"), 404, "not_found")
      assert request(base, :get, "/../mix.exs").body == "<div id=root></div>"
    end

    test "a lost database is a 503 with nothing internal in it" do
      conn = %{Plug.Test.conn(:get, "/api/auctions") | status: 500}
      reason = %DBConnection.ConnectionError{message: "password was hunter2"}
      sent = Router.handle_errors(conn, %{kind: :error, reason: reason, stack: []})

      assert sent.status == 503
      refute sent.resp_body =~ "hunter2"
    end
  end
end
