defmodule FileCacheTest do
  use ExUnit.Case, async: true
  doctest FileCache

  import FileCacheTest.Helpers

  @key "key"

  defp setup_cache(opts \\ []) do
    cache = start_cache(opts)
    on_exit(fn -> clean_cache(cache) end)

    [cache: cache]
  end

  describe "put! & get!" do
    setup do
      setup_cache()
    end

    test "returns nil for missing key", c do
      assert nil == FileCache.get!("not_exist", opts(c))
    end

    test "returns file stream with correct data for put data", c do
      content = binary()

      result = FileCache.put!(content, @key, opts(c))

      assert %File.Stream{} = result
      assert result == FileCache.get!(@key, opts(c))
      assert content == read!(result)
      assert content == read!(result.path)
    end

    test "works with binaries, iodata lists, streams, and funs returning them", c do
      run = fn id, content -> read!(FileCache.put!(content, id, opts(c))) end

      assert binary() == run.("binary", binary())
      assert binary() == run.("iodata", iodata())
      assert binary() == run.("stream", stream())
      assert binary() == run.("fn -> binary", fn -> binary() end)
      assert binary() == run.("fn -> iodata", fn -> iodata() end)
      assert binary() == run.("fn -> stream", fn -> stream() end)
    end

    test "automatically deletes stale ones", c do
      ttl = 100

      content = binary(1..5)

      prev = FileCache.put!(content, @key, opts(c, ttl: ttl))
      assert prev == FileCache.get!(@key, opts(c))
      # not deleted after `get!`: not yet expired
      assert content == read!(prev.path)

      # wait till expiration
      sleep(ttl)

      # trigger cleanup
      refute FileCache.get!(@key, opts(c))

      # wait some time for async cleanup
      wait_for_async_cleaning()

      refute File.exists?(prev.path)
    end

    test "automatically deletes all but the most recent on any operation (put)", c do
      # TODO
      previous_content = binary(1..5)
      current_content = binary(100..105)

      previous = FileCache.put!(previous_content, @key, opts(c))
      assert previous_content == read!(previous.path)

      # precautious step, since TTL resolution is 1 ms
      wait_for_new_timestamp()
      current = FileCache.put!(current_content, @key, opts(c))
      assert current_content == read!(current)

      # wait some time for async cleanup
      wait_for_async_cleaning()

      assert current_content == read!(current)
      refute File.exists?(previous.path)
      assert [_] = find_cache_files(opts(c))
    end

    test "when stream crashes, partial results are not visible and no files ", c do
      assert catch_throw(FileCache.put!(explosive_stream(), @key, opts(c))) == :explode
      refute FileCache.get!(@key, opts(c))
    end

    test "when stream crashes, temp and perm files are removed", c do
      assert catch_throw(FileCache.put!(explosive_stream(), @key, opts(c))) == :explode
      assert [] == find_cache_files(opts(c))
    end

    test "temp file is deleted if failed to move to perm location", _opts do
      dir = "/tmp/file_cache_unwritable"
      File.mkdir(dir)

      on_exit(fn ->
        chmod_r(dir, 0o700)
        File.rm_rf!(dir)
      end)

      # First: setup cache and create all necessary child dirs
      c = setup_cache(dir: dir)

      # Check that it works
      assert FileCache.put!("", @key, opts(c))

      # Now, we can restrict access to it
      chmod_r(dir, 0o400)

      assert %File.RenameError{reason: :eacces} = catch_error(FileCache.put!("", @key, opts(c)))
    end
  end

  describe "execute!" do
    setup do
      setup_cache()
    end

    test "writes data if there's nothing", c do
      data = 1..10

      assert binary(data) == read!(FileCache.execute!(notifying_stream(data), @key, opts(c)))

      for i <- data do
        assert_received ^i
      end

      assert binary(data) == read!(FileCache.get!(@key, opts(c)))
    end

    test "doesn't run stream if cache available", c do
      data = 1..10
      wrong_data = 101..110

      assert FileCache.execute!(stream(data), @key, opts(c))

      assert binary(data) ==
               read!(FileCache.execute!(notifying_stream(wrong_data), @key, opts(c)))

      refute_received _
      assert binary(data) == read!(FileCache.get!(@key, opts(c)))
    end
  end

  describe "delete!" do
    setup do
      setup_cache()
    end

    test "deletes all files, including the fresh one", c do
      assert FileCache.put!(binary(), @key, opts(c))
      assert :ok == FileCache.delete!(@key, opts(c))
      refute FileCache.get!(@key, opts(c))
      assert [] == find_cache_files(opts(c))
    end

    test "doesn't delete cache that was in computation when deletion took place", c do
      content = 1..5
      error = 100
      stream_interval = 100

      assert FileCache.put!(binary(), @key, opts(c))
      assert binary() == read!(FileCache.get!(@key, opts(c)))

      Task.start_link(fn ->
        FileCache.put!(slow_stream(content, stream_interval), @key, opts(c))
      end)

      assert :ok == FileCache.delete!(@key, opts(c))
      refute FileCache.get!(@key, opts(c))

      sleep(error + Enum.count(content) * stream_interval)
      assert binary(content) == read!(FileCache.get!(@key, opts(c)))
    end
  end

  describe ":unknown_files set to :remove" do
    test "still removes known files" do
      c = setup_cache(unknown_files: :remove)

      Enum.each(
        1..10,
        fn i ->
          assert "#{i}\n" == read!(FileCache.put!(binary([i]), @key, opts(c)))
        end
      )

      assert [_] = find_cache_files(opts(c))
    end

    test "removes files of unknown format" do
      temp_clean_interval = 250

      c = setup_cache(unknown_files: :remove, temp_clean_interval: temp_clean_interval)

      wrong_temp_file =
        Path.join([temp_dir(c[:cache]), "#{c[:cache]}", "temp-file-cache$_$_$#{@key}"])

      wrong_cache_file = Path.join([dir(c[:cache]), "#{c[:cache]}", "perm-file-cache$_$#{@key}"])

      assert FileCache.put!(binary(), @key, opts(c))
      assert binary() == read!(FileCache.get!(@key, opts(c)))

      File.write!(wrong_temp_file, "")
      File.write!(wrong_cache_file, "")

      assert binary() == read!(FileCache.get!(@key, opts(c)))
      wait_for_async_cleaning()
      sleep(temp_clean_interval)

      refute File.exists?(wrong_temp_file)
      refute File.exists?(wrong_cache_file)
    end
  end

  describe "init option :namespace" do
  end

  describe "init option :temp_namespace" do
  end

  describe "init option :ttl" do
  end

  describe "init option :verbose" do
  end

  describe "execute/put option :ttl" do
  end

  describe "StaleCleaner" do
    test "deletes all expired files", c do
    end

    test "deletes obsolete files when more fresh one is available", c do
    end

    test "is configured with :stale_clean_interval", c do
    end
  end

  describe "TempCleaner" do
    test "doesn't delete in-progress temp file", c do
    end

    test "removes temp file of a dead process", c do
    end

    test "is configured with :temp_clean_interval", c do
    end
  end
end
