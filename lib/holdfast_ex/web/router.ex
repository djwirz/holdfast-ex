defmodule HoldfastEx.Web.Router do
  @moduledoc """
  The contract (spec §6). Errors are always `{error, message}`, with nothing
  internal in them.
  """

  use Plug.Router
  use Plug.ErrorHandler

  alias HoldfastEx.Accounts
  alias HoldfastEx.Alias
  alias HoldfastEx.Auctions
  alias HoldfastEx.EventStore
  alias HoldfastEx.PublicView
  alias HoldfastEx.RateLimit
  alias HoldfastEx.Web.Page
  alias HoldfastEx.Web.SSE

  @cookie "holdfast_session"
  # Stripe's largest PaymentIntent amount: eight digits of cents.
  @max_amount 99_999_999
  @max_key_length 100
  @max_body_bytes 1_000

  plug(:page_files)
  plug(Plug.Head)
  plug(:check_origin)
  plug(:match)
  plug(:dispatch)

  get "/api/config" do
    json(conn, 200, %{
      githubSignIn: false,
      devSignIn: env(:dev_sign_in),
      # The in-memory adapter needs no card.
      cardRequired: false,
      stripePublishableKey: nil
    })
  end

  post "/api/auth/dev" do
    cond do
      not env(:dev_sign_in) ->
        not_found(conn)

      not RateLimit.allow?({:auth, conn.remote_ip}, env(:auth_rate_limit)) ->
        too_many(conn)

      true ->
        case body(conn) do
          {%{"login" => login}, conn} when is_binary(login) -> sign_in(conn, login)
          {_other, conn} -> bad_login(conn)
        end
    end
  end

  post "/api/auth/logout" do
    conn = fetch_cookies(conn)
    :ok = Accounts.sign_out(conn.req_cookies[@cookie])

    conn
    |> delete_resp_cookie(@cookie, cookie_options())
    |> send_resp(204, "")
  end

  get "/api/me" do
    signed_in(conn, "sign in first", fn conn, user ->
      json(conn, 200, %{user: %{login: user.login}, hasCard: false, cardRequired: false})
    end)
  end

  get "/api/auctions" do
    json(conn, 200, %{auctions: EventStore.list_auctions()})
  end

  get "/api/auctions/:id" do
    case Auctions.view(id) do
      {:ok, view} ->
        {conn, user} = current_user(conn)
        you = user && Alias.of(id, user.id)
        json(conn, 200, PublicView.snapshot(view, DateTime.utc_now(), you))

      {:error, :not_found} ->
        error(conn, 404, "not_found", "no such auction")

      {:error, :unavailable} ->
        unavailable(conn)
    end
  end

  get "/api/auctions/:id/events" do
    {conn, user} = current_user(conn)

    case SSE.stream(conn, id, user) do
      {:ok, conn} -> conn
      {:error, :not_found} -> error(conn, 404, "not_found", "no such auction")
      {:error, :unavailable} -> unavailable(conn)
    end
  end

  post "/api/auctions/:id/bids" do
    signed_in(conn, "sign in to bid", fn conn, user -> place_bid(conn, id, user) end)
  end

  get "/api/bids/:id" do
    signed_in(conn, "sign in first", fn conn, user ->
      # Someone else's bid is "not found", so its existence isn't confirmed.
      with {:ok, ^id} <- Ecto.UUID.cast(id),
           %{user_id: owner, auction_id: auction_id} when owner == user.id <-
             EventStore.bid_owner(id) do
        json(conn, 200, %{bid: read_bid(auction_id, id)})
      else
        _ -> error(conn, 404, "not_found", "no such bid")
      end
    end)
  end

  # Page routes such as /auctions/:id belong to the page. Anything under /api
  # stays a JSON 404.
  get "/*path" do
    case path do
      ["api" | _] -> not_found(conn)
      _ -> Page.index(conn) || not_found(conn)
    end
  end

  match _ do
    not_found(conn)
  end

  # -- bids ------------------------------------------------------------------

  defp place_bid(conn, auction_id, user) do
    with true <- RateLimit.allow?({:bid, user.id}, env(:bid_rate_limit)) || :rate_limited,
         {:ok, ^auction_id} <- Ecto.UUID.cast(auction_id),
         {:ok, key} <- idempotency_key(conn),
         {%{"amount" => amount} = body, conn} when map_size(body) == 1 <- body(conn),
         true <- (is_integer(amount) and amount in 1..@max_amount) || :bad_amount do
      bid = %{user_id: user.id, amount: amount, idempotency_key: key}
      answer(conn, auction_id, Auctions.place_bid(auction_id, bid))
    else
      :rate_limited ->
        too_many(conn)

      :error ->
        error(conn, 404, "not_found", "no such auction")

      {:ok, _not_canonical} ->
        error(conn, 404, "not_found", "no such auction")

      :bad_key ->
        error(conn, 400, "bad_request", "an Idempotency-Key header (1-100 chars) is required")

      _bad_body ->
        error(conn, 400, "bad_request", "amount must be a positive whole number of cents")
    end
  end

  defp answer(conn, auction_id, {:ok, %{id: bid_id}}) do
    bid = read_bid(auction_id, bid_id)
    json(conn, if(bid.status == "pending", do: 202, else: 201), %{bid: bid})
  end

  defp answer(conn, _auction_id, {:error, :not_found}),
    do: error(conn, 404, "not_found", "no such auction")

  defp answer(conn, _auction_id, {:error, :key_reused}) do
    message = "this Idempotency-Key was already used for a different bid"
    error(conn, 422, "idempotency_conflict", message)
  end

  defp answer(conn, _auction_id, {:error, :invalid_bid}),
    do: error(conn, 400, "bad_request", "amount must be a positive whole number of cents")

  defp answer(conn, _auction_id, {:error, _unavailable}), do: unavailable(conn)

  defp read_bid(auction_id, bid_id),
    do: auction_id |> EventStore.load_bid(bid_id) |> PublicView.bid(auction_id, bid_id)

  # Valid UTF-8 without NUL, which is what Postgres text can hold.
  defp idempotency_key(conn) do
    with [key] <- get_req_header(conn, "idempotency-key"),
         true <- String.valid?(key) and not String.contains?(key, <<0>>),
         length when length in 1..@max_key_length <- String.length(key) do
      {:ok, key}
    else
      _ -> :bad_key
    end
  end

  # -- sign-in ---------------------------------------------------------------

  defp sign_in(conn, login) do
    if Regex.match?(~r/\A[A-Za-z0-9-]{1,39}\z/, login) do
      token = Accounts.dev_sign_in(login)
      options = [max_age: Accounts.session_seconds()] ++ cookie_options()

      conn
      |> put_resp_cookie(@cookie, token, options)
      |> send_resp(204, "")
    else
      bad_login(conn)
    end
  end

  defp bad_login(conn),
    do: error(conn, 400, "bad_request", "login must be 1-39 of A-Z, a-z, 0-9, -")

  defp cookie_options,
    do: [path: "/", http_only: true, same_site: "Lax", secure: env(:secure_cookies)]

  defp current_user(conn) do
    conn = fetch_cookies(conn)
    {conn, Accounts.user(conn.req_cookies[@cookie])}
  end

  defp signed_in(conn, message, fun) do
    case current_user(conn) do
      {conn, nil} -> error(conn, 401, "unauthenticated", message)
      {conn, user} -> fun.(conn, user)
    end
  end

  # -- plugs and helpers -----------------------------------------------------

  defp page_files(conn, _opts), do: Page.static(conn)

  # State changes only from our own origin (spec §9). Compared with the configured
  # origin, never the request's Host.
  defp check_origin(%{method: method} = conn, _opts) when method in ["GET", "HEAD"], do: conn

  defp check_origin(conn, _opts) do
    if conn.request_path == "/api/stripe/webhook" or
         get_req_header(conn, "origin") == [env(:app_origin)] do
      conn
    else
      conn |> error(403, "forbidden", "cross-origin request refused") |> halt()
    end
  end

  # The decoded JSON body, or nil if there isn't a small, valid one.
  defp body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, decoded} -> {decoded, conn}
          {:error, _} -> {nil, conn}
        end

      {_too_big_or_broken, _, conn} ->
        {nil, conn}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  defp error(conn, status, error, message),
    do: json(conn, status, %{error: error, message: message})

  defp not_found(conn), do: error(conn, 404, "not_found", "not found")
  defp too_many(conn), do: error(conn, 429, "rate_limited", "too many requests")
  defp unavailable(conn), do: error(conn, 503, "unavailable", "try again in a moment")

  defp env(key), do: Application.fetch_env!(:holdfast_ex, key)

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %module{}})
      when module in [DBConnection.ConnectionError, Postgrex.Error],
      do: unavailable(conn)

  def handle_errors(conn, _error),
    do: error(conn, conn.status, "internal", "something went wrong")
end
