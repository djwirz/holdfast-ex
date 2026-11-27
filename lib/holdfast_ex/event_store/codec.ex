defmodule HoldfastEx.EventStore.Codec do
  @moduledoc """
  Event structs to and from the log's `type` and `data` columns.

  Every type is written out, and nothing read from the database becomes an atom
  unless it is on a list here. A reason is either one of our rules (an atom,
  stored as a string) or a provider's decline code (a string, stored as
  `{"code": ...}`). The two are kept apart because Stripe has decline codes
  spelled like our rules, such as `processing_error`.
  """

  alias HoldfastEx.Event

  @types %{
    Event.AuctionCreated => "auction_created",
    Event.BidPlaced => "bid_placed",
    Event.HoldAuthorized => "hold_authorized",
    Event.BidRejected => "bid_rejected",
    Event.BidAccepted => "bid_accepted",
    Event.BidLost => "bid_lost",
    Event.HoldReleased => "hold_released",
    Event.AuctionClosed => "auction_closed",
    Event.CaptureSucceeded => "capture_succeeded",
    Event.CaptureFailed => "capture_failed"
  }
  @modules Map.new(@types, fn {module, type} -> {type, module} end)

  @rules Map.new(
           [
             :below_minimum,
             :ended,
             :not_open,
             :not_covered,
             :authentication_required,
             :processing_error
           ],
           &{Atom.to_string(&1), &1}
         )

  @times [:starts_at, :ends_at]

  @spec encode(Event.data()) :: {String.t(), map()}
  def encode(%module{} = data) do
    fields =
      data
      |> Map.from_struct()
      |> Map.new(fn {field, value} -> {Atom.to_string(field), dump(module, field, value)} end)

    {Map.fetch!(@types, module), fields}
  end

  @doc "Raises on a type, version or field it doesn't know: a log it can't read."
  @spec decode(String.t(), pos_integer(), map()) :: Event.data()
  def decode(type, 1, fields) do
    module = Map.fetch!(@modules, type)

    values =
      for field <- Map.keys(module.__struct__()), field != :__struct__ do
        {field, load(module, field, Map.fetch!(fields, Atom.to_string(field)))}
      end

    struct!(module, values)
  end

  defp dump(_module, field, %DateTime{} = time) when field in @times,
    do: DateTime.to_iso8601(time)

  defp dump(module, :reason, reason)
       when module in [Event.BidRejected, Event.BidLost] and is_binary(reason),
       do: %{"code" => reason}

  defp dump(_module, :reason, reason) when is_atom(reason), do: Atom.to_string(reason)
  defp dump(_module, _field, value), do: value

  defp load(_module, field, value) when field in @times do
    {:ok, time, 0} = DateTime.from_iso8601(value)
    time
  end

  defp load(module, :reason, %{"code" => code})
       when module in [Event.BidRejected, Event.BidLost],
       do: code

  defp load(module, :reason, rule) when module in [Event.BidRejected, Event.BidLost],
    do: Map.fetch!(@rules, rule)

  defp load(_module, _field, value), do: value
end
