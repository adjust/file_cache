defmodule FileCache.Record do
  @moduledoc """
  Structure for FileCache record with cache id, content file's path, expiration timestamp, time-to-live and file stream,
  as returned by common FileCache operations
  """

  defstruct [:id, :path, :expires_at, :ttl, :stream]
end
