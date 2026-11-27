defmodule HoldfastEx.Payments.Memory do
  @moduledoc """
  An in-process payment provider for tests and local runs. Like Stripe with an
  idempotency key, it makes at most one hold per bid and repeats its first final
  answer. It outlives the auction servers, as Stripe does.

  Tests can `pause/0` it, so a hold exists but its answer hasn't arrived, and
  script what it says.
  """

  use GenServer

  @behaviour HoldfastEx.Payments

  @typedoc "What to say to a bid asking for the first time, or until it is final."
  @type answer :: :approve | {:decline, String.t() | atom()} | {:transient, term()} | :crash

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl HoldfastEx.Payments
  def authorize(request), do: unwrap(GenServer.call(__MODULE__, {:authorize, request}, :infinity))

  # A crash has to happen in the caller, not here.
  defp unwrap(:crash), do: raise("payment provider connection lost")
  defp unwrap(result), do: result

  @doc "Forgets every hold, script and pause."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "A function from a request and its attempt number (from 1) to an answer."
  @spec script((HoldfastEx.Payments.request(), pos_integer() -> answer())) :: :ok
  def script(fun), do: GenServer.call(__MODULE__, {:script, fun})

  @doc "From now on, answers wait for `release/1`. Holds are still made."
  def pause, do: GenServer.call(__MODULE__, :pause)

  @doc "Delivers the answers waiting for one bid, or for all and stops pausing."
  def release(bid_id \\ :all), do: GenServer.call(__MODULE__, {:release, bid_id})

  @doc "The bids whose answers are waiting."
  def waiting, do: GenServer.call(__MODULE__, :waiting)

  @doc "The holds made, as `%{bid_id => payment_intent_id}`."
  def holds, do: GenServer.call(__MODULE__, :holds)

  @doc "How often this bid has asked."
  def calls(bid_id), do: GenServer.call(__MODULE__, {:calls, bid_id})

  @impl GenServer
  def init(nil), do: {:ok, fresh()}

  defp fresh do
    %{
      script: fn _request, _attempt -> :approve end,
      paused?: false,
      answers: %{},
      calls: %{},
      waiting: %{}
    }
  end

  @impl GenServer
  def handle_call({:authorize, request}, from, state) do
    %{bid_id: bid_id} = request
    attempt = Map.get(state.calls, bid_id, 0) + 1
    state = put_in(state.calls[bid_id], attempt)
    {result, state} = answer(state, request, attempt)

    if state.paused? do
      waiter = {from, result}

      {:noreply,
       update_in(state.waiting, &Map.update(&1, bid_id, [waiter], fn w -> [waiter | w] end))}
    else
      {:reply, result, state}
    end
  end

  def handle_call(:reset, _from, state) do
    flush(state.waiting)
    {:reply, :ok, fresh()}
  end

  def handle_call({:script, fun}, _from, state), do: {:reply, :ok, %{state | script: fun}}
  def handle_call(:pause, _from, state), do: {:reply, :ok, %{state | paused?: true}}

  def handle_call({:release, :all}, _from, state) do
    flush(state.waiting)
    {:reply, :ok, %{state | paused?: false, waiting: %{}}}
  end

  def handle_call({:release, bid_id}, _from, state) do
    {released, waiting} = Map.split(state.waiting, [bid_id])
    flush(released)
    {:reply, :ok, %{state | waiting: waiting}}
  end

  def handle_call(:waiting, _from, state), do: {:reply, Map.keys(state.waiting), state}

  def handle_call(:holds, _from, state) do
    holds = for {bid_id, {:ok, intent, _}} <- state.answers, into: %{}, do: {bid_id, intent}
    {:reply, holds, state}
  end

  def handle_call({:calls, bid_id}, _from, state),
    do: {:reply, Map.get(state.calls, bid_id, 0), state}

  defp answer(%{answers: answers} = state, %{bid_id: bid_id} = request, attempt) do
    case answers do
      %{^bid_id => result} ->
        {result, state}

      _ ->
        case state.script.(request, attempt) do
          :approve -> final(state, bid_id, {:ok, "pi_#{bid_id}", request.amount})
          {:decline, reason} -> final(state, bid_id, {:error, reason})
          other -> {other, state}
        end
    end
  end

  defp final(state, bid_id, result), do: {result, put_in(state.answers[bid_id], result)}

  defp flush(waiting) do
    Enum.each(waiting, fn {_bid_id, waiters} ->
      Enum.each(waiters, fn {from, result} -> GenServer.reply(from, result) end)
    end)
  end
end
