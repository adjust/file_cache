defmodule FileCache.Cleaner do
  @type opts :: %{
          cache_name: FileCache.cache_name()
        }
  @type state :: %{
          cache_name: FileCache.cache_name()
        }

  @callback name(opts) :: atom
  @callback cleanup(state) :: any
  @optional_callbacks name: 1

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour unquote(__MODULE__)

      alias FileCache.Config
      alias FileCache.Temp
      alias __MODULE__, as: S

      require Logger

      @typep t :: %__MODULE__{
               timer: nil | reference,
               cache_name: FileCache.cache_name()
             }

      @default_keys [timer: nil]
      @enforce_keys [:cache_name]
      defstruct @default_keys ++ @enforce_keys

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      def init(opts) do
        state = %S{
          cache_name: opts[:cache_name]
        }

        {:ok, state, {:continue, :initial_cleanup}}
      end

      def handle_continue(:initial_cleanup, state) do
        {:noreply, cleanup_and_schedule(state)}
      end

      def handle_info(:cleanup, state) do
        {:noreply, cleanup_and_schedule(state)}
      end

      defp cleanup_and_schedule(state) do
        if Config.get(state.cache_name, :verbose) do
          Logger.info("Starting cleanup for #{state.cache_name}")
        end

        new_state = schedule_cleanup(state)
        cleanup(state)
        new_state
      end

      defp schedule_cleanup(%S{cache_name: cache_name, timer: timer} = state) do
        _ = timer && :erlang.cancel_timer(timer)

        timer =
          :erlang.start_timer(
            Config.get(cache_name, :temp_clean_interval),
            self(),
            :cleanup
          )

        %S{state | timer: timer}
      end
    end
  end
end
