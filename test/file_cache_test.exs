defmodule FileCacheTest do
  use ExUnit.Case, async: true
  doctest FileCache

  import FileCacheTest.Helpers

  @temp_prefix "temp-file-cache"
  @cache_prefix "perm-file-cache"
  @key "key"

  defp setup_cache(opts \\ []) do
    cache = start_cache(opts)
    on_exit(fn -> clean_cache(cache) end)

    Keyword.merge(opts, cache: cache)
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

      wait(ttl)

      # trigger cleanup
      refute FileCache.get!(@key, opts(c))

      wait_for_cleaning()

      refute File.exists?(prev.path)
    end

    test "automatically deletes all but the most recent on any operation (put)", c do
      # TODO
      previous_content = binary(1..5)
      current_content = binary(100..105)

      previous = FileCache.put!(previous_content, @key, opts(c))
      assert previous_content == read!(previous.path)

      wait_for_new_timestamp()
      current = FileCache.put!(current_content, @key, opts(c))
      assert current_content == read!(current)

      wait_for_cleaning()

      assert current_content == read!(current)
      refute File.exists?(previous.path)
      assert [_] = find_cache_files(opts(c))
    end

    test "when stream crashes, partial results are not visible", c do
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

  describe "get_record!" do
    setup do
      setup_cache(ttl: 60_000)
    end

    test "returns nil for missing key", c do
      assert nil == FileCache.get_record!("not_exist", opts(c))
    end

    test "get complete record about cache file", c do
      data = 1..10

      start_timestamp = FileCache.Utils.system_time()
      assert binary(data) == read!(FileCache.put!(binary(data), @key, opts(c)))

      assert %FileCache.Record{
               id: id,
               path: path,
               stream: stream,
               expires_at: expires_at,
               ttl: ttl
             } = FileCache.get_record!(@key, opts(c))

      assert @key == id
      assert binary(data) == read!(stream)
      assert binary(data) == read!(File.stream!(path))

      assert 59_000 <= ttl and ttl < 61_000

      test_ttl = expires_at - start_timestamp
      assert 59_000 <= test_ttl and test_ttl < 61_000
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

    test "doesn't delete in-flight cache", c do
      data = 1..10
      stream_interval = 100

      assert FileCache.put!(binary(), @key, opts(c))
      assert binary() == read!(FileCache.get!(@key, opts(c)))

      async(FileCache.put!(slow_stream(data, stream_interval), @key, opts(c)))

      assert :ok == FileCache.delete!(@key, opts(c))
      refute FileCache.get!(@key, opts(c))

      wait_for_slow_stream(data, stream_interval)
      assert binary(data) == read!(FileCache.get!(@key, opts(c)))
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
        Path.join([temp_dir(c[:cache]), "#{c[:cache]}", "#{@temp_prefix}$_$_$#{@key}"])

      wrong_cache_file = Path.join([dir(c[:cache]), "#{c[:cache]}", "#{@cache_prefix}$_$#{@key}"])

      assert FileCache.put!(binary(), @key, opts(c))
      assert binary() == read!(FileCache.get!(@key, opts(c)))

      File.touch!(wrong_temp_file)
      File.touch!(wrong_cache_file)

      assert_logs(
        [
          {:error,
           "FileCache (#{c[:cache]}): Incorrect filepath timestamp: " <>
             "/tmp/file_cache_test_#{c[:cache]}/perm/#{c[:cache]}/#{@cache_prefix}$_$#{@key}"},
          {:error,
           "FileCache (#{c[:cache]}): Incorrect temp filepath pid: " <>
             "/tmp/file_cache_test_#{c[:cache]}/temp/#{c[:cache]}/#{@temp_prefix}$_$_$#{@key}"}
        ],
        fn ->
          assert binary() == read!(FileCache.get!(@key, opts(c)))
          wait_for_cleaning(temp_clean_interval)
        end,
        order: false
      )

      refute File.exists?(wrong_temp_file)
      refute File.exists?(wrong_cache_file)
    end
  end

  describe "init option :namespace" do
    test "no dirs when empty" do
      # [] and nil are essentially the same
      c = setup_cache(namespace: [])
      assert FileCache.put!(binary(), @key, opts(c))
      assert [_] = File.ls!(Path.join([dir(c[:cache]), "#{c[:cache]}"]))
    end

    test "support all namespace parts (:host, mfa, fun/0, binary)" do
      {:ok, host} = :inet.gethostname()

      c =
        setup_cache(
          namespace: [
            :host,
            "cache_sample_dir",
            {FileCacheTest.Helpers, :namespace_fun, ["calculated_cache_dirname"]},
            fn -> "another_cache_dirname" end
          ]
        )

      assert FileCache.put!(binary(), @key, opts(c))

      assert [_] =
               File.ls!(
                 Path.join([
                   dir(c[:cache]),
                   "#{host}",
                   "cache_sample_dir",
                   "calculated_cache_dirname",
                   "another_cache_dirname",
                   "#{c[:cache]}"
                 ])
               )
    end
  end

  describe "init option :temp_namespace" do
    test "no dirs when empty" do
      data = 1..5
      stream_interval = 100
      # [] and nil are essentially the same
      c = setup_cache(temp_namespace: nil)

      async(assert FileCache.put!(slow_stream(data, stream_interval), @key, opts(c)))
      wait(stream_interval)
      assert [_] = File.ls!(Path.join([temp_dir(c[:cache]), "#{c[:cache]}"]))
    end

    test "support all namespace parts (:host, mfa, fun/0, binary)" do
      {:ok, host} = :inet.gethostname()
      data = 1..5
      stream_interval = 100

      c =
        setup_cache(
          temp_namespace: [
            :host,
            "temp_sample_dir",
            {FileCacheTest.Helpers, :namespace_fun, ["calculated_temp_dirname"]},
            fn -> "another_temp_dirname" end
          ]
        )

      async(assert FileCache.put!(slow_stream(data, stream_interval), @key, opts(c)))
      wait(stream_interval)

      assert [_] =
               File.ls!(
                 Path.join([
                   temp_dir(c[:cache]),
                   "#{host}",
                   "temp_sample_dir",
                   "calculated_temp_dirname",
                   "another_temp_dirname",
                   "#{c[:cache]}"
                 ])
               )
    end
  end

  describe "init option :ttl" do
    test "short-lived cache is deleted almost instantly" do
      c = setup_cache(ttl: 1)
      assert s = %File.Stream{} = FileCache.put!(binary(), @key, opts(c))
      wait_for_cleaning(2000)
      refute File.exists?(s.path)
      refute read!(s)
    end
  end

  describe "init option :verbose" do
    test "no logs when false" do
      assert_logs([], fn ->
        setup_cache(verbose: false)
        wait_for_cleaning()
      end)
    end

    test "logs cleaning start when true" do
      name = String.to_atom(random_string())

      assert_logs(
        [
          {:info, "Starting stale cleanup for #{name}"},
          {:info, "Starting temp cleanup for #{name}"}
        ],
        fn ->
          setup_cache(cache: name, verbose: true)
          wait_for_cleaning()
        end,
        order: false
      )
    end
  end

  describe "execute/put option :ttl" do
    test "overrides global ttl" do
      c = setup_cache(ttl: 1)

      assert FileCache.put!(binary(), @key, opts(c))
      wait_for_new_timestamp()
      refute FileCache.get!(@key, opts(c))

      assert FileCache.put!(binary(), @key, opts(c, ttl: 60_000))
      assert binary() == read!(FileCache.get!(@key, opts(c)))
    end
  end

  describe "stats/1" do
    setup do
      setup_cache()
    end

    test "returns correct stats + config for the cache", c do
      fast_iters = 10
      slow_iters = 3

      init_stats = FileCache.stats(opts(c))
      assert %{current: 0, in_progress: 0} == init_stats

      for i <- 1..fast_iters, do: FileCache.put!(binary(), "fast-#{i}", opts(c))
      for i <- 1..slow_iters, do: async(FileCache.put!(slow_stream(), "slow-#{i}", opts(c)))
      wait_for_slow_stream(1..1)

      stats = FileCache.stats(opts(c))
      assert %{current: fast_iters, in_progress: slow_iters} == stats
    end
  end

  describe "config/1" do
    test "returns correct (default) config" do
      c = setup_cache()

      stats = FileCache.config(opts(c))
      assert match?(%{cache: _}, stats)

      assert %{
               cache: stats.cache,
               dir: "/tmp/file_cache_test_#{stats.cache}/perm",
               namespace: nil,
               stale_clean_interval: 3_600_000,
               temp_clean_interval: 900_000,
               temp_dir: "/tmp/file_cache_test_#{stats.cache}/temp",
               temp_namespace: nil,
               ttl: 3_600_000,
               unknown_files: :keep,
               verbose: false
             } == stats
    end

    test "returns correct config for all changed values" do
      cache = :my_custom_cache

      settings = [
        cache: cache,
        dir: "/tmp/file_cache_test_#{cache}_dir",
        ttl: 42,
        namespace: :host,
        stale_clean_interval: 123,
        temp_dir: "/tmp/file_cache_test_#{cache}_temp_dir",
        temp_namespace: "temp_namespace",
        temp_clean_interval: 1337,
        unknown_files: :remove,
        verbose: true
      ]

      _ = setup_cache(settings)

      assert Map.new(settings) == FileCache.config(cache: cache)
    end
  end

  describe "clean/1" do
    setup do
      setup_cache()
    end

    test "cleans and writes w/o problems after that", c do
      range = 1..10
      for i <- range, do: FileCache.put!(binary(), "#{i}", opts(c))
      assert :ok == FileCache.clean(opts(c))
      for i <- range, do: assert(nil == FileCache.get!("#{i}", opts(c)))

      for i <- range, do: FileCache.put!(binary(), "#{i}", opts(c))
      for i <- range, do: assert(binary() == read!(FileCache.get!("#{i}", opts(c))))
    end
  end

  describe "StaleCleaner" do
    test "deletes all expired files" do
      c = setup_cache(ttl: 1000)
      ids = Enum.map(1..5, &to_string/1)
      Enum.each(ids, fn i -> assert FileCache.put!(binary(), i, opts(c)) end)
      Enum.each(ids, fn i -> assert binary() == read!(FileCache.get!(i, opts(c))) end)

      wait(c[:ttl])
      restart_cache(opts(c))
      wait_for_cleaning()
      Enum.each(ids, fn i -> refute FileCache.get!(i, opts(c)) end)
    end

    test "deletes obsolete files when more fresh one is available" do
      c = setup_cache()
      data = 1..5
      stream_interval = 100
      async(assert FileCache.put!(slow_stream(data, stream_interval), @key, opts(c)))
      async(assert FileCache.put!(slow_stream(data, stream_interval), @key, opts(c)))
      wait_for_slow_stream(data, stream_interval)
      restart_cache(c)
      assert [_] = find_cache_files(c)
    end

    test "is configured with :stale_clean_interval" do
      stale_clean_interval = 1000

      c =
        setup_cache(ttl: div(stale_clean_interval, 2), stale_clean_interval: stale_clean_interval)

      wait_for_cleaning()
      assert FileCache.put!(binary(), @key, opts(c))
      assert binary() == read!(FileCache.get!(@key, opts(c)))
      wait(stale_clean_interval)

      refute FileCache.get!(@key, opts(c))
    end
  end

  describe "TempCleaner" do
    test "doesn't delete in-progress temp file and is configured with :temp_clean_interval" do
      temp_clean_interval = 100
      data = 1..5
      stream_interval = 100
      c = setup_cache(temp_clean_interval: temp_clean_interval)
      async(assert FileCache.put!(slow_stream(data, stream_interval), @key, opts(c)))
      wait()
      assert [_] = find_cache_files(c)
      wait_for_slow_stream(data, stream_interval)
      assert [_] = find_cache_files(c)
      assert FileCache.get!(@key, opts(c))
    end

    test "removes temp file of a dead process" do
      temp_clean_interval = 200
      c = setup_cache(temp_clean_interval: temp_clean_interval)
      pid = async(FileCache.put!(slow_stream(), @key, opts(c)))
      wait()
      assert [_] = find_cache_files(c)
      assert_kill(pid)

      wait(temp_clean_interval)
      assert [] == find_cache_files(c)
    end

    test "removes the waste if stream has exited" do
      temp_clean_interval = 100
      c = setup_cache(temp_clean_interval: temp_clean_interval)
      Process.flag(:trap_exit, true)
      pid = async(FileCache.put!(self_terminating_stream(), @key, opts(c)))
      wait(temp_clean_interval)
      assert_received {:EXIT, ^pid, :killed}
      assert [] == find_cache_files(opts(c))
    end
  end
end
