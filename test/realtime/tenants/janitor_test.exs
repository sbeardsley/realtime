defmodule Realtime.Tenants.JanitorTest do
  # async: false due to using database process
  alias Realtime.Tenants
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog

  alias Realtime.Api.Message
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Repo
  alias Realtime.Tenants.Migrations
  alias Realtime.Tenants.Janitor

  setup do
    dev_tenant = Tenant |> Repo.all() |> hd()
    timer = Application.get_env(:realtime, :janitor_schedule_timer)

    Application.put_env(:realtime, :janitor_schedule_timer, 200)
    Application.put_env(:realtime, :janitor_schedule_randomize, false)
    Application.put_env(:realtime, :janitor_chunk_size, 2)

    tenants =
      Enum.map(
        [
          tenant_fixture(),
          dev_tenant
        ],
        fn tenant ->
          tenant = Repo.preload(tenant, [:extensions])
          [%{settings: settings} | _] = tenant.extensions
          migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}
          Migrations.run_migrations(migrations)
          {:ok, conn} = Database.connect(tenant, "realtime_test", 1)
          clean_table(conn, "realtime", "messages")
          Tenants.track_active_tenant(tenant.external_id)
          tenant
        end
      )

    start_supervised!(
      {Task.Supervisor,
       name: Realtime.Tenants.Janitor.TaskSupervisor,
       max_children: 2,
       max_seconds: 500,
       max_restarts: 1}
    )

    on_exit(fn ->
      Application.put_env(:realtime, :janitor_schedule_timer, timer)
    end)

    %{tenants: tenants}
  end

  test "cleans messages older than 72 hours from tenants that were active and untracks the user",
       %{
         tenants: tenants
       } do
    utc_now = NaiveDateTime.utc_now()
    limit = NaiveDateTime.add(utc_now, -72, :hour)

    messages =
      for days <- -5..0 do
        inserted_at = NaiveDateTime.add(utc_now, days, :day)
        Enum.map(tenants, &message_fixture(&1, %{inserted_at: inserted_at}))
      end
      |> List.flatten()
      |> MapSet.new()

    to_keep =
      messages
      |> Enum.reject(&(NaiveDateTime.compare(limit, &1.inserted_at) == :gt))
      |> MapSet.new()

    start_supervised!(Janitor)
    Process.sleep(500)

    current =
      Enum.map(tenants, fn tenant ->
        {:ok, conn} = Database.connect(tenant, "realtime_test", 1)
        {:ok, res} = Repo.all(conn, from(m in Message), Message)
        res
      end)
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.difference(current, to_keep) |> MapSet.size() == 0
    assert Tenants.list_active_tenants() == []
  end

  test "logs error if fails to connect to tenant" do
    extensions = [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "localhost",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
          "db_password" => "bad",
          "db_port" => "5433",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1",
          "ssl_enforced" => false
        }
      }
    ]

    tenant = tenant_fixture(%{extensions: extensions})
    Tenants.track_active_tenant(tenant.external_id)

    assert capture_log(fn ->
             start_supervised!(Janitor)
             Process.sleep(1000)
           end) =~ "JanitorFailedToDeleteOldMessages"
  end
end
