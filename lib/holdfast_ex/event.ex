defmodule HoldfastEx.Event do
  @moduledoc """
  One entry in an auction's log (spec §4).

  `data` is a struct per event type, so the type is the struct's module. `v` is
  the schema version of that struct (ADR 0003). `seq` and `at` are set by
  whatever appends the event: the core returns events without them, and `at` is
  the database's time once there is a database.

  `auction_extended` isn't here yet: soft close is a stretch (spec §11).
  """

  defmodule AuctionCreated do
    @moduledoc false
    @enforce_keys [:title, :starts_at, :ends_at, :starting_price, :min_increment]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            title: String.t(),
            starts_at: DateTime.t(),
            ends_at: DateTime.t(),
            starting_price: pos_integer(),
            min_increment: pos_integer()
          }
  end

  defmodule BidPlaced do
    @moduledoc false
    @enforce_keys [:bid_id, :user_id, :amount, :idempotency_key]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            bid_id: String.t(),
            user_id: String.t(),
            amount: pos_integer(),
            idempotency_key: String.t()
          }
  end

  defmodule HoldAuthorized do
    @moduledoc false
    @enforce_keys [:bid_id, :payment_intent_id, :amount_capturable]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            bid_id: String.t(),
            payment_intent_id: String.t(),
            amount_capturable: non_neg_integer()
          }
  end

  defmodule BidRejected do
    @moduledoc false
    @enforce_keys [:bid_id, :reason]
    defstruct @enforce_keys

    @typedoc "A rule, a payment failure, or the provider's decline code as a string."
    @type reason ::
            :below_minimum
            | :ended
            | :not_open
            | :authentication_required
            | :processing_error
            | String.t()

    @type t :: %__MODULE__{bid_id: String.t(), reason: reason()}
  end

  defmodule BidAccepted do
    @moduledoc false
    @enforce_keys [:bid_id, :amount, :alias, :previous_high_bid_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            bid_id: String.t(),
            amount: pos_integer(),
            alias: String.t(),
            previous_high_bid_id: String.t() | nil
          }
  end

  defmodule BidLost do
    @moduledoc false
    @enforce_keys [:bid_id, :reason]
    defstruct @enforce_keys

    @typedoc "Why an authorized bid no longer qualified."
    @type reason :: :below_minimum | :ended | :not_open | :not_covered

    @type t :: %__MODULE__{bid_id: String.t(), reason: reason()}
  end

  defmodule HoldReleased do
    @moduledoc false
    @enforce_keys [:payment_intent_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{payment_intent_id: String.t()}
  end

  defmodule AuctionClosed do
    @moduledoc false
    @enforce_keys [:winner_bid_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{winner_bid_id: String.t() | nil}
  end

  defmodule CaptureSucceeded do
    @moduledoc false
    @enforce_keys [:payment_intent_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{payment_intent_id: String.t()}
  end

  defmodule CaptureFailed do
    @moduledoc false
    @enforce_keys [:payment_intent_id, :reason]
    defstruct @enforce_keys

    @type t :: %__MODULE__{payment_intent_id: String.t(), reason: String.t()}
  end

  @enforce_keys [:data]
  defstruct [:seq, :at, :data, v: 1]

  @type data ::
          AuctionCreated.t()
          | BidPlaced.t()
          | HoldAuthorized.t()
          | BidRejected.t()
          | BidAccepted.t()
          | BidLost.t()
          | HoldReleased.t()
          | AuctionClosed.t()
          | CaptureSucceeded.t()
          | CaptureFailed.t()

  @type t :: %__MODULE__{
          seq: pos_integer() | nil,
          at: DateTime.t() | nil,
          data: data(),
          v: pos_integer()
        }

  @doc "Whether SSE clients see this event (spec §4)."
  @spec public?(t()) :: boolean()
  def public?(%__MODULE__{data: %BidAccepted{}}), do: true
  def public?(%__MODULE__{data: %AuctionClosed{}}), do: true
  def public?(%__MODULE__{}), do: false
end
