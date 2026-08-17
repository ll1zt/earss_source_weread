defmodule EarssSourceWeread.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    _ = maybe_register()
    _ = schedule_register_retries()

    children = []
    opts = [strategy: :one_for_one, name: EarssSourceWeread.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp schedule_register_retries do
    spawn(fn ->
      Enum.each(1..30, fn _ ->
        Process.sleep(200)

        case maybe_register() do
          :ok -> :ok
          :already -> :ok
          _ -> :ok
        end
      end)
    end)
  end

  # Host Earss exposes Earss.Source.Registry. When running this package alone
  # (mix test), the module is absent — skip registration quietly.
  defp maybe_register do
    registry = Module.concat([Earss, Source, Registry])

    if Process.whereis(registry) &&
         Code.ensure_loaded?(registry) &&
         function_exported?(registry, :register, 1) do
      case apply(registry, :register, [
             %{
               id: EarssSourceWeread.Adapter.id(),
               module: EarssSourceWeread.Adapter,
               version: "0.1.0"
             }
           ]) do
        :ok -> :ok
        {:error, :already_registered} -> :already
        other -> other
      end
    else
      :waiting
    end
  rescue
    _ -> :waiting
  catch
    :exit, _ -> :waiting
  end
end
