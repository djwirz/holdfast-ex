defmodule HoldfastEx.Web.Page do
  @moduledoc """
  The built page, served from this origin (ADR 0011), so the cookie and the origin
  check need nothing extra. With no page built, there is nothing to serve.
  """

  import Plug.Conn

  @doc "Serves the request if it names a file of the built page."
  def static(conn) do
    case dir() do
      nil ->
        conn

      dir ->
        # Vite fingerprints what is under assets/, so those never change.
        cache =
          if match?(["assets" | _], conn.path_info),
            do: "public, max-age=31536000, immutable",
            else: "no-cache"

        options = Plug.Static.init(at: "/", from: dir, headers: %{"cache-control" => cache})
        Plug.Static.call(conn, options)
    end
  end

  @doc "Sends the page's shell, or returns nil if there is no page."
  def index(conn) do
    with dir when dir != nil <- dir() do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, Path.join(dir, "index.html"))
    end
  end

  defp dir do
    dir = Application.get_env(:holdfast_ex, :web_dist)
    if dir && File.regular?(Path.join(dir, "index.html")), do: dir
  end
end
