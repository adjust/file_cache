defmodule FileCacheTest do
  use ExUnit.Case, async: true
  doctest FileCache

  import FileCacheTest.Helpers

  defp setup_cache(opts \\ []) do
    cache = start_cache(opts)
    on_exit(fn -> clean_cache(cache) end)

    [cache: cache]
  end

  describe "put! & get!" do
    setup do
      setup_cache()
    end

    test "returns nil for missing key", opts do
      assert nil == FileCache.get!("not_exist", opts(opts))
    end

    test "returns file stream with correct data for put data", opts do
      key = "key"
      content = binary()
      read_content = iolist()

      result = FileCache.put!(content, key, opts(opts))
      assert read_content == read!(result)
      assert read_content == read!(FileCache.get!(key, opts(opts)))
    end

    test "automatically deletes all but the most recent on get" do
    end

    test "partial results are not visible" do
    end

    test "no temp files" do
    end

    test "temp file is deleted if stream crashed" do
    end

    test "temp file is deleted if failed to move to perm location" do
    end
  end

  describe "execute!" do
    test "writes data if there's nothing" do
    end

    test "doesn't run stream if cache available" do
    end
  end

  describe "delete!" do
  end

  describe ":unknown_files set to :remove" do
    test "still removes known files" do
    end

    test "removes files of unknown format" do
    end
  end

  describe ":namespace option" do
  end

  describe "is configured with :temp_namespace" do
  end

  describe ":ttl option" do
  end

  describe ":verbose option" do
  end

  describe "StaleCleaner" do
    test "deletes all expired files" do
    end

    test "deletes obsolete files when more fresh one is available" do
    end

    test "is configured with :stale_clean_interval" do
    end
  end

  describe "TempCleaner" do
    test "doesn't delete in-progress temp file" do
    end

    test "removes temp file of a dead process" do
    end

    test "is configured with :temp_clean_interval" do
    end
  end

  describe ":unknown_files set to :keep" do
    test "still removes known files" do
    end

    test "ignores files of unknown format" do
    end
  end
end
