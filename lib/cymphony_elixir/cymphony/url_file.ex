defmodule CymphonyElixir.Cymphony.UrlFile do
  @moduledoc """
  Tiny on-disk cache of the running daemon's dashboard URL so the
  `cymphony webui` CLI subcommand (a separate OS process) can find and
  open it in a browser.
  """

  @path "~/.cymphony/dashboard.url"

  @spec path() :: Path.t()
  def path, do: Path.expand(@path)

  @spec write(String.t()) :: :ok | {:error, term()}
  def write(url) when is_binary(url) do
    expanded = path()
    :ok = File.mkdir_p(Path.dirname(expanded))

    case File.write(expanded, url) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @spec read() :: {:ok, String.t()} | {:error, :not_running}
  def read do
    case File.read(path()) do
      {:ok, content} ->
        url = String.trim(content)
        if url == "", do: {:error, :not_running}, else: {:ok, url}

      {:error, _} ->
        {:error, :not_running}
    end
  end

  @spec delete() :: :ok
  def delete do
    _ = File.rm(path())
    :ok
  end
end
