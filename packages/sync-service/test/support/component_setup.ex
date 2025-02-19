defmodule Support.ComponentSetup do
  import ExUnit.Callbacks
  import ExUnit.Assertions
  import Support.TestUtils, only: [full_test_name: 1]

  alias Electric.Replication.ShapeLogCollector
  alias Electric.ShapeCache
  alias Electric.ShapeCache.FileStorage
  alias Electric.ShapeCache.InMemoryStorage
  alias Electric.Postgres.Inspector.EtsInspector

  def with_stack_id_from_test(ctx) do
    stack_id = full_test_name(ctx)
    registry = start_link_supervised!({Electric.ProcessRegistry, stack_id: stack_id})
    %{stack_id: stack_id, process_registry: registry}
  end

  def with_registry(ctx) do
    registry_name = :"#{Registry.ShapeChanges}:#{ctx.stack_id}"
    start_link_supervised!({Registry, keys: :duplicate, name: registry_name})

    %{registry: registry_name}
  end

  def with_in_memory_storage(ctx) do
    storage_opts =
      InMemoryStorage.shared_opts(
        table_base_name: :"in_memory_storage_#{ctx.stack_id}",
        stack_id: ctx.stack_id
      )

    %{storage: {InMemoryStorage, storage_opts}}
  end

  def with_no_pool(_ctx) do
    %{pool: :no_pool}
  end

  def with_cub_db_storage(ctx) do
    storage_opts =
      FileStorage.shared_opts(
        storage_dir: ctx.tmp_dir,
        stack_id: ctx.stack_id
      )

    %{storage: {FileStorage, storage_opts}}
  end

  def with_persistent_kv(_ctx) do
    kv = Electric.PersistentKV.Memory.new!()
    %{persistent_kv: kv}
  end

  def with_log_chunking(_ctx) do
    %{chunk_bytes_threshold: Electric.ShapeCache.LogChunker.default_chunk_size_threshold()}
  end

  def with_shape_cache(ctx, additional_opts \\ []) do
    server = :"shape_cache_#{full_test_name(ctx)}"
    consumer_supervisor = :"consumer_supervisor_#{full_test_name(ctx)}"
    get_pg_version = fn -> Application.fetch_env!(:electric, :pg_version_for_tests) end

    start_opts =
      [
        name: server,
        stack_id: ctx.stack_id,
        inspector: ctx.inspector,
        storage: ctx.storage,
        chunk_bytes_threshold: ctx.chunk_bytes_threshold,
        db_pool: ctx.pool,
        registry: ctx.registry,
        log_producer: ctx.shape_log_collector,
        consumer_supervisor: consumer_supervisor
      ]
      |> Keyword.merge(additional_opts)
      |> Keyword.put_new_lazy(:prepare_tables_fn, fn ->
        {
          Electric.Postgres.Configuration,
          :configure_tables_for_replication!,
          [get_pg_version, ctx.publication_name]
        }
      end)

    {:ok, _pid} =
      Electric.Shapes.DynamicConsumerSupervisor.start_link(
        name: consumer_supervisor,
        stack_id: ctx.stack_id
      )

    {:ok, _pid} = ShapeCache.start_link(start_opts)

    shape_meta_table = ShapeCache.get_shape_meta_table(stack_id: ctx.stack_id)

    shape_cache_opts = [
      stack_id: ctx.stack_id,
      server: server,
      storage: ctx.storage,
      shape_meta_table: shape_meta_table
    ]

    %{
      shape_cache_opts: shape_cache_opts,
      shape_cache: {ShapeCache, shape_cache_opts},
      shape_cache_server: server,
      consumer_supervisor: consumer_supervisor,
      shape_meta_table: shape_meta_table
    }
  end

  def with_shape_log_collector(ctx) do
    {:ok, _} =
      ShapeLogCollector.start_link(
        stack_id: ctx.stack_id,
        inspector: ctx.inspector
      )

    %{shape_log_collector: ShapeLogCollector.name(ctx.stack_id)}
  end

  def with_slot_name_and_stream_id(_ctx) do
    # Use a random slot name to avoid conflicts
    %{
      slot_name: "electric_test_slot_#{:rand.uniform(10_000)}",
      stream_id: "default"
    }
  end

  def with_inspector(ctx) do
    {:ok, server} =
      EtsInspector.start_link(stack_id: ctx.stack_id, pool: ctx.db_conn)

    pg_info_table = EtsInspector.get_column_info_table(stack_id: ctx.stack_id)
    pg_relation_table = EtsInspector.get_relation_table(stack_id: ctx.stack_id)

    %{
      inspector: {EtsInspector, stack_id: ctx.stack_id, server: server},
      pg_info_table: pg_info_table,
      pg_relation_table: pg_relation_table
    }
  end

  def with_complete_stack(ctx) do
    stack_id = full_test_name(ctx)

    kv = %Electric.PersistentKV.Memory{
      parent: self(),
      pid: start_supervised!(Electric.PersistentKV.Memory, restart: :temporary)
    }

    storage = {FileStorage, stack_id: stack_id, storage_dir: ctx.tmp_dir}

    stack_events_registry = Registry.StackEvents

    ref = make_ref()
    Electric.StackSupervisor.subscribe_to_stack_events(stack_events_registry, stack_id, ref)

    stack_supervisor =
      start_supervised!(
        {Electric.StackSupervisor,
         stack_id: stack_id,
         stack_events_registry: stack_events_registry,
         persistent_kv: kv,
         storage: storage,
         connection_opts: ctx.db_config,
         replication_opts: [
           slot_name: "electric_test_slot_#{:erlang.phash2(stack_id)}",
           publication_name: "electric_test_pub_#{:erlang.phash2(stack_id)}",
           try_creating_publication?: true,
           slot_temporary?: true
         ],
         pool_opts: [
           backoff_type: :stop,
           max_restarts: 0,
           pool_size: 2
         ],
         tweaks: [registry_partitions: 1]},
        restart: :temporary
      )

    assert_receive {:stack_status, ^ref, :ready}

    # Process.sleep(100)

    %{
      stack_id: stack_id,
      stack_events_registry: stack_events_registry,
      persistent_kv: kv,
      stack_supervisor: stack_supervisor,
      storage: storage
    }
  end

  def build_router_opts(ctx, overrides \\ []) do
    [
      long_poll_timeout: 4_000,
      max_age: 60,
      stale_age: 300,
      allow_shape_deletion: true
    ]
    |> Keyword.merge(
      Electric.StackSupervisor.build_shared_opts(
        stack_id: ctx.stack_id,
        stack_events_registry: ctx.stack_events_registry,
        storage: ctx.storage
      )
    )
    |> Keyword.merge(overrides)
  end
end
