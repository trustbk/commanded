defmodule Commanded.Commands.DispatchConsistencyTest do
  use Commanded.StorageCase

  alias Commanded.Commands.ExecutionResult
  alias Commanded.EventStore

  defmodule ConsistencyCommand do
    defstruct [:uuid, :delay]
  end

  defmodule NoOpCommand do
    defstruct [:uuid]
  end

  defmodule RequestDispatchCommand do
    defstruct [:uuid, :delay]
  end

  defmodule ConsistencyEvent do
    defstruct [:delay]
  end

  defmodule DispatchRequestedEvent do
    defstruct [:uuid, :delay]
  end

  defmodule ConsistencyAggregateRoot do
    defstruct [:delay]

    def execute(%ConsistencyAggregateRoot{}, %ConsistencyCommand{delay: delay}) do
      %ConsistencyEvent{delay: delay}
    end

    def execute(%ConsistencyAggregateRoot{}, %NoOpCommand{}), do: []

    def execute(%ConsistencyAggregateRoot{}, %RequestDispatchCommand{uuid: uuid, delay: delay}) do
      %DispatchRequestedEvent{uuid: uuid, delay: delay}
    end

    def apply(%ConsistencyAggregateRoot{} = aggregate, %ConsistencyEvent{delay: delay}) do
      %ConsistencyAggregateRoot{aggregate | delay: delay}
    end

    def apply(%ConsistencyAggregateRoot{} = aggregate, _event), do: aggregate
  end

  defmodule ConsistencyRouter do
    use Commanded.Commands.Router

    dispatch [ConsistencyCommand,NoOpCommand,RequestDispatchCommand],
      to: ConsistencyAggregateRoot,
      identity: :uuid
  end

  defmodule ConsistencyPrefixRouter do
    use Commanded.Commands.Router

    identify ConsistencyAggregateRoot,
        by: :uuid,
        prefix: "example-prefix-"

    dispatch [ConsistencyCommand,NoOpCommand,RequestDispatchCommand],
      to: ConsistencyAggregateRoot
  end

  defmodule StronglyConsistentEventHandler do
    use Commanded.Event.Handler,
      name: "StronglyConsistentEventHandler",
      consistency: :strong

    def handle(%ConsistencyEvent{delay: delay}, _metadata) do
      :timer.sleep(delay)
      :ok
    end

    # handle event by dispatching a command
    def handle(%DispatchRequestedEvent{uuid: uuid, delay: delay}, _metadata) do
      :timer.sleep(delay)
      ConsistencyRouter.dispatch(%ConsistencyCommand{uuid: uuid, delay: delay}, consistency: :strong)
    end
  end

  defmodule EventuallyConsistentEventHandler do
    use Commanded.Event.Handler,
      name: "EventuallyConsistentEventHandler",
      consistency: :eventual

    def handle(%ConsistencyEvent{}, _metadata) do
      :timer.sleep(:infinity) # simulate slow event handler
      :ok
    end

    # handle event by dispatching a command
    def handle(%DispatchRequestedEvent{uuid: uuid, delay: delay}, _metadata) do
      ConsistencyRouter.dispatch(%ConsistencyCommand{uuid: uuid, delay: delay})
    end
  end

  setup do
    {:ok, handler1} = StronglyConsistentEventHandler.start_link()
    {:ok, handler2} = EventuallyConsistentEventHandler.start_link()

    on_exit fn ->
      Commanded.Helpers.Process.shutdown(handler1)
      Commanded.Helpers.Process.shutdown(handler2)
    end

    :ok
  end

  test "should wait for strongly consistent event handler to handle event" do
    command = %ConsistencyCommand{uuid: UUID.uuid4(), delay: 0}
    assert :ok = ConsistencyRouter.dispatch(command, consistency: :strong)
  end

  # default consistency timeout set to 100ms test config
  test "should timeout waiting for strongly consistent event handler to handle event" do
    command = %ConsistencyCommand{uuid: UUID.uuid4(), delay: 5_000}
    assert {:error, :consistency_timeout} = ConsistencyRouter.dispatch(command, consistency: :strong)
  end

  test "should not wait when command creates no events" do
    command = %NoOpCommand{uuid: UUID.uuid4()}
    assert :ok = ConsistencyRouter.dispatch(command, consistency: :strong)
  end

  test "should allow strongly consistent event handler to dispatch a command" do
    command = %RequestDispatchCommand{uuid: UUID.uuid4(), delay: 0}
    assert :ok = ConsistencyRouter.dispatch(command, consistency: :strong)
  end

  test "should timeout waiting for strongly consistent handler dispatching a command" do
    command = %RequestDispatchCommand{uuid: UUID.uuid4(), delay: 5_000}
    assert {:error, :consistency_timeout} = ConsistencyRouter.dispatch(command, consistency: :strong)
  end

  describe "aggregate identity prefix" do
    test "should wait for strongly consistent event handler to handle event" do
      uuid = UUID.uuid4()
      command = %ConsistencyCommand{uuid: uuid, delay: 0}

      assert :ok = ConsistencyPrefixRouter.dispatch(command, consistency: :strong)
    end

    test "should append events to stream using prefixed aggregate uuid" do
      uuid = UUID.uuid4()
      command = %ConsistencyCommand{uuid: uuid, delay: 0}

      assert {:ok, %ExecutionResult{aggregate_uuid: aggregate_uuid}}
        = ConsistencyPrefixRouter.dispatch(command, consistency: :strong, include_execution_result: true)

      assert aggregate_uuid == "example-prefix-" <> uuid

      recorded_events = EventStore.stream_forward(aggregate_uuid) |> Enum.to_list()
      assert length(recorded_events) == 1
    end
  end
end
