defmodule HoldfastEx.Accounts do
  @moduledoc """
  Users and sessions (spec §9). The cookie carries 32 random bytes and the table
  stores only their SHA-256, so a copy of the database signs nobody in. Expiry is
  by database time.
  """

  alias HoldfastEx.Repo

  @session_seconds 7 * 24 * 60 * 60

  @type user :: %{id: String.t(), login: String.t()}

  def session_seconds, do: @session_seconds

  @doc "Signs a dev login in, creating it the first time, and returns the cookie value."
  @spec dev_sign_in(String.t()) :: String.t()
  def dev_sign_in(login) do
    %{rows: [[user_id]]} =
      Repo.query!(
        "INSERT INTO users (login, dev) VALUES ($1, true) " <>
          "ON CONFLICT (dev, login) DO UPDATE SET login = EXCLUDED.login RETURNING id",
        [login]
      )

    token = :crypto.strong_rand_bytes(32)

    %{num_rows: 1} =
      Repo.query!(
        "INSERT INTO sessions (id, user_id, expires_at) " <>
          "VALUES ($1, $2, now() + make_interval(secs => $3))",
        [hash(token), user_id, @session_seconds / 1]
      )

    Base.url_encode64(token, padding: false)
  end

  @spec user(String.t() | nil) :: user() | nil
  def user(cookie) do
    with {:ok, token} <- decode(cookie),
         %{rows: [[id, login]]} <-
           Repo.query!(
             "SELECT u.id, u.login FROM sessions s JOIN users u ON u.id = s.user_id " <>
               "WHERE s.id = $1 AND s.expires_at > now()",
             [hash(token)]
           ) do
      %{id: Ecto.UUID.load!(id), login: login}
    else
      _ -> nil
    end
  end

  @spec sign_out(String.t() | nil) :: :ok
  def sign_out(cookie) do
    case decode(cookie) do
      {:ok, token} ->
        %{} = Repo.query!("DELETE FROM sessions WHERE id = $1", [hash(token)])
        :ok

      :error ->
        :ok
    end
  end

  defp decode(cookie) when is_binary(cookie), do: Base.url_decode64(cookie, padding: false)
  defp decode(nil), do: :error

  defp hash(token), do: :crypto.hash(:sha256, token)
end
