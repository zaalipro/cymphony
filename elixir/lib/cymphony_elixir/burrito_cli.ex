defmodule CymphonyElixir.BurritoCLI do
  @moduledoc """
  OTP Application entrypoint for the Burrito-wrapped standalone binary.
  Starts the full Cymphony supervision tree, then hands off to CLI.main/1.
  """

  use Application

  alias Burrito.Util.Args
  alias CymphonyElixir.Application, as: CymphonyApplication
  alias CymphonyElixir.CLI

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = CymphonyElixir.LogFile.configure()
    children = CymphonyApplication.children()

    with {:ok, sup_pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: CymphonyElixir.Supervisor) do
      args = Args.argv()

      Task.start(fn ->
        try do
          CLI.main(args)
        catch
          kind, reason ->
            Logger.error("Unhandled CLI error: #{inspect({kind, reason})}")
            System.halt(1)
        end
      end)

      {:ok, sup_pid}
    end
  end

  @impl true
  def stop(_state) do
    CymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
