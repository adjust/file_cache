defmodule FileCache.Cleaner do
  @moduledoc false

  @type opts :: %{
          cache: FileCache.cache_name()
        }
  @type state :: %{
          cache: FileCache.cache_name()
        }

  @callback name(opts) :: atom
  @callback cleanup(state) :: any
  @optional_callbacks name: 1

  defmacro __using__(opts) do
    kind = opts[:kind]

    quote do
      use GenServer
      @behaviour unquote(__MODULE__)

      alias FileCache.Config
      alias FileCache.Temp
      alias __MODULE__, as: S

      require Logger

      @typep t :: %__MODULE__{
               timer: nil | reference,
               cache: FileCache.cache_name()
             }

      @default_keys [timer: nil]
      @enforce_keys [:cache]
      defstruct @default_keys ++ @enforce_keys

      def start_link(args) do
        opts =
          case function_exported?(__MODULE__, :name, 1) do
            true -> [name: apply(__MODULE__, :name, [args])]
            false -> []
          end

        GenServer.start_link(__MODULE__, args, opts)
      end

      def init(opts) do
        state = %S{
          cache: opts[:cache]
        }

        {:ok, state, {:continue, :initial_cleanup}}
      end

      @spec handle_continue(:initial_cleanup, t) :: {:noreply, t}
      def handle_continue(:initial_cleanup, state) do
        {:noreply, cleanup_and_schedule(state)}
      end

      @spec handle_info(any, t) :: {:noreply, t}
      def handle_info(:cleanup, state) do
        {:noreply, cleanup_and_schedule(state)}
      end

      defp cleanup_and_schedule(state) do
        if Config.get(state.cache, :verbose) do
          Logger.info("Starting #{unquote(kind)} cleanup for #{state.cache}")
        end

        new_state = schedule_cleanup(state)
        cleanup(state)
        new_state
      end

      defp schedule_cleanup(%S{cache: cache_name, timer: timer} = state) do
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
