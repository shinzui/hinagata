#!/usr/bin/env python3
"""Reproducible disposable-cluster fixture measurements."""

import hashlib
import json
import math
import os
import pathlib
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone


PROJECT = pathlib.Path(__file__).resolve().parents[1]
RESULTS = PROJECT / "bench" / "results"
STAMP = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
ARTIFACT = RESULTS / STAMP
SMALL_REPS = int(os.environ.get("BENCH_REPS_SMALL", "30"))
BULK_REPS = int(os.environ.get("BENCH_REPS_BULK", "5"))
BULK_ROWS = [int(value) for value in os.environ.get("BENCH_ROWS_BULK", "100000,1000000").split(",") if value]


def run(command, *, env=None, input=None, check=True):
    start = time.monotonic_ns()
    completed = subprocess.run(command, env=env, input=input, text=True, capture_output=True)
    elapsed_ms = (time.monotonic_ns() - start) / 1_000_000
    if check and completed.returncode:
        raise RuntimeError(f"{command!r} failed ({completed.returncode})\n{completed.stdout}\n{completed.stderr}")
    return completed, elapsed_ms


def version(command):
    result, _ = run(command)
    return result.stdout.strip()


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def summary(samples, key):
    values = [sample[key] for sample in samples]
    return {"count": len(values), "median": statistics.median(values), "p95_nearest_rank": percentile(values, 0.95)}


def write_fixture(root, name, body):
    directory = root / name
    directory.mkdir(parents=True)
    (directory / "fixture.sql").write_text(body)


def small_cases(workspace, binary):
    root = workspace / "fixtures"
    bundles = workspace / "bundles"
    bundles.mkdir()
    write_fixture(root, "base", "CREATE TABLE public.hinagata_bench_rows (id integer PRIMARY KEY, payload text NOT NULL);\n")
    for rows in (100, 1000):
        values = ",\n".join(f"({number}, 'payload{number}')" for number in range(1, rows + 1))
        write_fixture(root, f"scenario-{rows}", f"INSERT INTO public.hinagata_bench_rows (id, payload) VALUES\n{values};\n")
    config = workspace / "hinagata.yaml"
    config.write_text(
        "project:\n  id: performance\nbaseline:\n  fixtures: [base]\n"
        "migration:\n  executable: cat\n  revision: benchmark-noop-migration-v1\n"
        "verification:\n  executable: cat\n  revision: benchmark-noop-verification-v1\n"
    )
    env = os.environ.copy()
    env.update(
        HINAGATA_ENDPOINT_HOST=env["HINAGATA_TEST_PGHOST"],
        HINAGATA_ENDPOINT_PORT=env["HINAGATA_TEST_PGPORT"],
        HINAGATA_FIXTURE_ROOT=str(root),
        HINAGATA_BUNDLE_ROOT=str(bundles),
        HINAGATA_MAINTENANCE_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_ADMINISTRATION_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_ADMINISTRATION_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_SETUP_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_SETUP_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_APPLICATION_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_APPLICATION_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        hinagata_postgres_datadir=str(PROJECT / "hinagata-postgres"),
    )
    base = [binary, "--config", str(config)]
    cold, cold_ms = run(base + ["db", "prepare", "--json"], env=env)
    warm, warm_ms = run(base + ["db", "prepare", "--json"], env=env)
    cold_report, warm_report = json.loads(cold.stdout), json.loads(warm.stdout)
    assert cold_report["result"] == "Built" and warm_report["result"] == "Reused"
    cases = {}
    for rows in (100, 1000):
        samples = []
        for index in range(SMALL_REPS + 2):
            command = base + ["db", "with", "--fixture", f"scenario-{rows}", "--json", "--", "true"]
            completed, elapsed_ms = run(command, env=env)
            report = json.loads(completed.stdout)
            assert report["ok"] and report["disposition"] == "LeaseReleased" and report["status"] == 0
            if index >= 2:
                samples.append({"outer_ms": elapsed_ms, **{f"{key}_ms": value for key, value in report["timingsMs"].items()}})
        rebuilds = []
        for index in range(5):
            changed = env.copy()
            changed["HINAGATA_MIGRATION_REVISION"] = f"benchmark-small-{rows}-rebuild-{index}"
            prepared, prepare_ms = run(base + ["db", "prepare", "--json"], env=changed)
            assert json.loads(prepared.stdout)["result"] == "Built"
            completed, scope_ms = run(base + ["db", "with", "--fixture", f"scenario-{rows}", "--json", "--", "true"], env=changed)
            assert json.loads(completed.stdout)["disposition"] == "LeaseReleased"
            rebuilds.append({"prepare_ms": prepare_ms, "scope_ms": scope_ms, "total_ms": prepare_ms + scope_ms})
        cases[str(rows)] = {
            "scenario_sha256": hashlib.sha256((root / f"scenario-{rows}" / "fixture.sql").read_bytes()).hexdigest(),
            "samples": samples,
            "setup": summary(samples, "outer_ms"),
            "clone": summary(samples, "clone_ms"),
            "scenario_load": summary(samples, "scenarioLoad_ms"),
            "completion": summary(samples, "completion_ms"),
            "full_rebuild": {"samples": rebuilds, "total": summary(rebuilds, "total_ms")},
        }
    return {"cold_prepare_ms": cold_ms, "warm_prepare_ms": warm_ms, "cold_report": cold_report, "warm_report": warm_report, "cases": cases}


def csv_file(path, rows):
    digest = hashlib.sha256()
    with path.open("wb") as target:
        for first in range(1, rows + 1, 1000):
            chunk = "".join(f"{number},payload\n" for number in range(first, min(rows + 1, first + 1000))).encode()
            target.write(chunk)
            digest.update(chunk)
    return digest.hexdigest()


def fresh_bulk_database(env):
    database = "hinagata_bench_bulk"
    connection = ["-h", env["HINAGATA_TEST_PGHOST"], "-p", env["HINAGATA_TEST_PGPORT"], "-U", env["HINAGATA_TEST_PGUSER"]]
    run(["dropdb", "--if-exists", *connection, database])
    run(["createdb", *connection, database])
    return database, connection


def bulk_cases(workspace, binary):
    env = os.environ.copy()
    cases = {}
    for rows in BULK_ROWS:
        source = workspace / f"rows-{rows}.csv"
        digest = csv_file(source, rows)
        table = f"hinagata_bench_{rows}"
        sql = workspace / f"psql-{rows}.sql"
        sql.write_text(
            "\\timing on\nBEGIN;\n"
            f"CREATE TABLE public.{table} (id integer PRIMARY KEY, payload text NOT NULL);\n"
            f"\\copy public.{table} (id, payload) FROM '{source}' WITH (FORMAT csv)\n"
            "COMMIT;\n"
        )
        measured = {"hinagata": [], "psql": []}
        for method in ("hinagata", "psql"):
            for index in range(BULK_REPS + 1):
                database, connection = fresh_bulk_database(env)
                if method == "hinagata":
                    bench_env = env.copy()
                    bench_env["HINAGATA_TEST_PGDATABASE"] = database
                    result, elapsed_ms = run(["/usr/bin/time", "-l", binary, str(rows), "+RTS", "-s", "-RTS"], env=bench_env)
                    copy = re.search(r"\bcopy_ms=(\d+)", result.stdout)
                    load = re.search(r"\bload_ms=(\d+)", result.stdout)
                    residency = re.search(r"([\d,]+) bytes maximum residency", result.stderr)
                    allocated = re.search(r"([\d,]+) bytes allocated in the heap", result.stderr)
                    rss = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
                    sent = re.search(r"\bbytes=(\d+)", result.stdout)
                    if not all((copy, load, residency, allocated, rss, sent)):
                        raise RuntimeError(f"Could not parse GHC/time stats:\n{result.stdout}\n{result.stderr}")
                    schema_bytes = len(f"CREATE TABLE {table} (id integer PRIMARY KEY, payload text NOT NULL);".encode())
                    if int(sent[1]) - schema_bytes != source.stat().st_size:
                        raise RuntimeError("Hinagata transferred a different CSV byte count than the psql input")
                    sample = {"outer_ms": elapsed_ms, "load_ms": int(load[1]), "copy_ms": int(copy[1]), "rts_residency_bytes": int(residency[1].replace(",", "")), "rts_allocated_bytes": int(allocated[1].replace(",", "")), "rss_bytes": int(rss[1])}
                else:
                    result, elapsed_ms = run(["/usr/bin/time", "-l", "psql", *connection, "-d", database, "-v", "ON_ERROR_STOP=1", "-f", str(sql)], env=env)
                    copy = re.search(rf"COPY {rows}\s+Time: ([\d.]+) ms", result.stdout)
                    rss = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
                    if not copy or not rss:
                        raise RuntimeError(f"Could not parse psql/time stats:\n{result.stdout}\n{result.stderr}")
                    sample = {"outer_ms": elapsed_ms, "copy_ms": float(copy[1]), "rss_bytes": int(rss[1])}
                if index:
                    measured[method].append(sample)
            run(["dropdb", "--if-exists", *connection, database])
        cases[str(rows)] = {
            "csv_sha256": digest,
            "csv_bytes": source.stat().st_size,
            "hinagata": {"samples": measured["hinagata"], "copy": summary(measured["hinagata"], "copy_ms"), "residency": summary(measured["hinagata"], "rts_residency_bytes")},
            "psql": {"samples": measured["psql"], "copy": summary(measured["psql"], "copy_ms")},
        }
    return cases


def lifecycle_cases(workspace, cli):
    source = workspace / "rows-1000000.csv"
    if not source.exists():
        return None
    root = workspace / "bulk-fixtures"
    base = root / "bulk-base"
    base.mkdir(parents=True)
    (base / "fixture.yaml").write_text(
        "name: bulk-base\nsteps:\n  - sql: schema.sql\n"
        "  - copy:\n      table: {schema: public, name: hinagata_bench_1000000}\n"
        "      columns: [id, payload]\n      file: rows.csv\n      format: csv\n      header: false\n"
    )
    (base / "schema.sql").write_text("CREATE TABLE public.hinagata_bench_1000000 (id integer PRIMARY KEY, payload text NOT NULL);\n")
    os.link(source, base / "rows.csv")
    bundles = workspace / "bulk-bundles"
    bundles.mkdir()
    config = workspace / "bulk-hinagata.yaml"
    config.write_text(
        "project:\n  id: performance-bulk\nbaseline:\n  fixtures: [bulk-base]\n"
        "migration:\n  executable: cat\n  revision: benchmark-bulk-noop-v1\n"
        "verification:\n  executable: cat\n  revision: benchmark-bulk-noop-v1\n"
    )
    env = os.environ.copy()
    env.update(
        HINAGATA_ENDPOINT_HOST=env["HINAGATA_TEST_PGHOST"],
        HINAGATA_ENDPOINT_PORT=env["HINAGATA_TEST_PGPORT"],
        HINAGATA_FIXTURE_ROOT=str(root),
        HINAGATA_BUNDLE_ROOT=str(bundles),
        HINAGATA_MAINTENANCE_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_ADMINISTRATION_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_ADMINISTRATION_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_SETUP_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_SETUP_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_APPLICATION_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_APPLICATION_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        hinagata_postgres_datadir=str(PROJECT / "hinagata-postgres"),
    )
    command = [cli, "--config", str(config)]
    checkpoint_query = ["psql", "-h", env["HINAGATA_TEST_PGHOST"], "-p", env["HINAGATA_TEST_PGPORT"], "-U", env["HINAGATA_TEST_PGUSER"], "-d", env["HINAGATA_TEST_PGDATABASE"], "-Atc", "SELECT num_requested, num_done FROM pg_stat_checkpointer"]

    def checkpoints():
        result, _ = run(checkpoint_query, env=env)
        return tuple(map(int, result.stdout.strip().split("|")))

    planned, compile_ms = run(command + ["fixture", "plan", "bulk-base", "--json"], env=env)
    assert json.loads(planned.stdout)["ok"]
    cold, cold_ms = run(command + ["db", "prepare", "--json"], env=env)
    warm, warm_ms = run(command + ["db", "prepare", "--json"], env=env)
    assert json.loads(cold.stdout)["result"] == "Built" and json.loads(warm.stdout)["result"] == "Reused"
    samples = {"WAL_LOG": [], "FILE_COPY": []}
    for index in range(6):
        for strategy in samples:
            before = checkpoints()
            prepared = command + ["--set", f"clone.strategy={strategy}", "db", "with", "--fixture", "bulk-base", "--json", "--", "true"]
            result, elapsed_ms = run(prepared, env=env)
            after = checkpoints()
            report = json.loads(result.stdout)
            assert report["ok"] and report["disposition"] == "LeaseReleased"
            if index:
                samples[strategy].append({"outer_ms": elapsed_ms, "checkpoints_requested_delta": after[0] - before[0], "checkpoints_done_delta": after[1] - before[1], **{f"{key}_ms": value for key, value in report["timingsMs"].items()}})
    rebuild = []
    for index in range(5):
        changed = env.copy()
        changed["HINAGATA_MIGRATION_REVISION"] = f"benchmark-bulk-rebuild-{index}"
        result, elapsed_ms = run(command + ["db", "prepare", "--json"], env=changed)
        report = json.loads(result.stdout)
        assert report["result"] == "Built"
        rebuild.append({"outer_ms": elapsed_ms, "reported_ms": report["elapsedMs"]})
    return {
        "cold_bundle_plan_ms": compile_ms,
        "cold_prepare_ms": cold_ms,
        "warm_prepare_ms": warm_ms,
        "clone": {strategy: {"samples": values, "phase": summary(values, "clone_ms"), "scope": summary(values, "outer_ms")} for strategy, values in samples.items()},
        "full_rebuild": {"samples": rebuild, "scope": summary(rebuild, "outer_ms")},
        "file_copy_checkpoint_note": "PostgreSQL checkpoints before and after FILE_COPY clone creation; this cost can affect other workloads.",
    }


def concurrent_cases(workspace, binary):
    fixture_root = workspace / "bulk-fixtures"
    if not fixture_root.exists():
        return None
    bundle_root = workspace / "concurrency-bundles"
    bundle_root.mkdir()
    env = os.environ.copy()
    env["BENCH_FIXTURE_ROOT"] = str(fixture_root)
    env["BENCH_BUNDLE_ROOT"] = str(bundle_root)
    observer = ["psql", "-h", env["HINAGATA_TEST_PGHOST"], "-p", env["HINAGATA_TEST_PGPORT"], "-U", env["HINAGATA_TEST_PGUSER"], "-d", env["HINAGATA_TEST_PGDATABASE"], "-Atc"]
    query = "SELECT count(*) FILTER (WHERE state = 'active' AND query LIKE 'CREATE DATABASE%'), count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid()"
    result = {}
    for count in (1, 4, 8):
        samples = []
        for index in range(4):
            process = subprocess.Popen([binary, str(count)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            max_creates = 0
            max_connections = 0
            while process.poll() is None:
                observed, _ = run(observer + [query], env=env)
                active, connections = map(int, observed.stdout.strip().split("|"))
                max_creates = max(max_creates, active)
                max_connections = max(max_connections, connections)
                time.sleep(0.01)
            stdout, stderr = process.communicate()
            if process.returncode:
                raise RuntimeError(f"concurrent lease benchmark failed: {stderr}")
            report = json.loads(stdout)
            assert report["concurrency"] == count and len(report["timings"]) == count
            if index:
                samples.append({"elapsed_ms": report["elapsedMs"], "throughput_leases_per_second": count * 1000 / report["elapsedMs"], "request_tail_ms": max(item["requestMs"] for item in report["timings"]), "max_active_create": max_creates, "max_connections_excluding_observer": max_connections, "leases": report["timings"]})
        result[str(count)] = {"samples": samples, "elapsed": summary(samples, "elapsed_ms"), "throughput": summary(samples, "throughput_leases_per_second"), "request_tail": summary(samples, "request_tail_ms"), "max_observed_create": max(sample["max_active_create"] for sample in samples), "max_observed_connections": max(sample["max_connections_excluding_observer"] for sample in samples)}
    return result


def spare_clone_cases(workspace, cli):
    config = workspace / "bulk-hinagata.yaml"
    if not config.exists():
        return None
    env = os.environ.copy()
    env.update(
        HINAGATA_ENDPOINT_HOST=env["HINAGATA_TEST_PGHOST"],
        HINAGATA_ENDPOINT_PORT=env["HINAGATA_TEST_PGPORT"],
        HINAGATA_FIXTURE_ROOT=str(workspace / "bulk-fixtures"),
        HINAGATA_BUNDLE_ROOT=str(workspace / "bulk-bundles"),
        HINAGATA_MAINTENANCE_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_ADMINISTRATION_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_ADMINISTRATION_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_SETUP_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_SETUP_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        HINAGATA_APPLICATION_USER=env["HINAGATA_TEST_PGUSER"],
        HINAGATA_APPLICATION_DATABASE=env["HINAGATA_TEST_PGDATABASE"],
        hinagata_postgres_datadir=str(PROJECT / "hinagata-postgres"),
    )
    command = [cli, "--config", str(config)]
    connection = ["-h", env["HINAGATA_TEST_PGHOST"], "-p", env["HINAGATA_TEST_PGPORT"], "-U", env["HINAGATA_TEST_PGUSER"]]
    observer = ["psql", *connection, "-d", env["HINAGATA_TEST_PGDATABASE"], "-Atc", "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid()"]

    def acquire():
        result, elapsed_ms = run(command + ["db", "acquire", "--fixture", "bulk-base", "--json"], env=env)
        report = json.loads(result.stdout)
        assert report["ok"] and report["database"] and report["leaseId"]
        return {"lease": report["leaseId"], "database": report["database"], "acquire_ms": elapsed_ms}

    def probe(lease):
        _, elapsed_ms = run(["psql", *connection, "-d", lease["database"], "-v", "ON_ERROR_STOP=1", "-Atc", "SELECT 1"], env=env)
        return elapsed_ms

    def acquire_and_probe():
        lease = acquire()
        lease["ready_ms"] = lease["acquire_ms"] + probe(lease)
        return lease

    def release(leases):
        for lease in leases:
            result, _ = run(command + ["db", "release", lease["lease"], "--json"], env=env)
            assert json.loads(result.stdout)["ok"]

    def batch(actions):
        started = time.monotonic_ns()
        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(action) for action in actions]
            maximum = 0
            while not all(future.done() for future in futures):
                observed, _ = run(observer, env=env)
                maximum = max(maximum, int(observed.stdout.strip()))
                time.sleep(0.01)
            values = [future.result() for future in futures]
        return values, (time.monotonic_ns() - started) / 1_000_000, maximum

    on_demand = []
    on_demand_connections = []
    for _ in range(3):
        leases, _, maximum = batch([acquire_and_probe] * 4)
        on_demand_connections.append(maximum)
        for lease in leases:
            on_demand.append({"ready_ms": lease["ready_ms"], "acquire_ms": lease["acquire_ms"]})
        release(leases)

    spares, preparation_ms, prep_connections = batch([acquire] * 4)
    disk_bytes = 0
    for spare in spares:
        result, _ = run(["psql", *connection, "-d", env["HINAGATA_TEST_PGDATABASE"], "-Atc", f"SELECT pg_database_size('{spare['database']}')"], env=env)
        disk_bytes += int(result.stdout.strip())
    ready, _, handoff_connections = batch([lambda lease=lease: probe(lease) for lease in spares])
    release(spares)
    replenished, replenishment_ms, replenish_connections = batch([acquire] * 4)
    release(replenished)
    return {
        "concurrency": 4,
        "on_demand": {"samples": on_demand, "ready": summary(on_demand, "ready_ms"), "max_connections": max(on_demand_connections)},
        "prepared_spares": {"handoff_samples_ms": ready, "handoff_median_ms": statistics.median(ready), "handoff_p95_nearest_rank_ms": percentile(ready, 0.95), "preparation_ms": preparation_ms, "replenishment_ms": replenishment_ms, "disk_bytes": disk_bytes, "max_connections": max(prep_connections, handoff_connections, replenish_connections)},
        "interpretation": "Detached owned leases simulate one-shot prepared spares; no clone is reused after a test.",
    }


def render_summary(result):
    lines = []
    for rows, case in result["small"]["cases"].items():
        lines.append(f"{rows} rows warm scope: median={case['setup']['median']:.1f} ms p95={case['setup']['p95_nearest_rank']:.1f} ms n={case['setup']['count']}")
    for rows, case in result["bulk"].items():
        ratio = result["gates"]["copy_ratios"][rows]
        lines.append(f"{rows} rows COPY: Hinagata={case['hinagata']['copy']['median']:.1f} ms psql={case['psql']['copy']['median']:.1f} ms ratio={ratio:.2f} n={case['hinagata']['copy']['count']}")
    if result["lifecycle"]:
        lifecycle = result["lifecycle"]
        lines.append(f"1m clone WAL_LOG={lifecycle['clone']['WAL_LOG']['phase']['median']:.1f} ms FILE_COPY={lifecycle['clone']['FILE_COPY']['phase']['median']:.1f} ms; rebuild={lifecycle['full_rebuild']['scope']['median']:.1f} ms")
    if result["concurrency"]:
        for count, case in result["concurrency"].items():
            lines.append(f"concurrency {count}: throughput={case['throughput']['median']:.2f} leases/s tail={case['request_tail']['median']:.1f} ms max_active_create={case['max_observed_create']}")
    if result["spare_clones"]:
        spare = result["spare_clones"]
        lines.append(f"four-spare experiment: on-demand p95={spare['on_demand']['ready']['p95_nearest_rank']:.1f} ms prepared-handoff p95={spare['prepared_spares']['handoff_p95_nearest_rank_ms']:.1f} ms disk={spare['prepared_spares']['disk_bytes']} bytes")
    gates = result["gates"]
    lines.append(f"gates: small_setup={gates['small_setup']} copy_ratio={gates['copy_ratio']} incremental_client_rss={gates['incremental_client_rss']} valid_sample_counts={gates['valid_sample_counts']}")
    return "\n".join(lines) + "\n"


def main():
    if SMALL_REPS < 1 or BULK_REPS < 1:
        raise SystemExit("repetition counts must be positive")
    ARTIFACT.mkdir(parents=True, exist_ok=False)
    cli = version(["cabal", "list-bin", "hinagata"])
    bench = version(["cabal", "list-bin", "hinagata-postgres-direct-load"])
    concurrent = version(["cabal", "list-bin", "hinagata-postgres-concurrent-leases"])
    metadata = {
        "timestamp_utc": STAMP,
        "platform": platform.platform(),
        "processor": platform.processor(),
        "cpu_model": version(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "ghc": version(["ghc", "--numeric-version"]),
        "postgres": version(["postgres", "--version"]),
        "psql": version(["psql", "--version"]),
        "small_repetitions": SMALL_REPS,
        "bulk_repetitions": BULK_REPS,
        "warmup_repetitions": {"small": 2, "bulk": 1},
        "postgres_cluster": "disposable socket-only, default durability, trust auth",
        "filesystem_cache": "warm after first sample; no cache flush",
        "rts_flags": "+RTS -s -RTS",
        "storage": version(["df", "-h", str(ARTIFACT)]),
    }
    with tempfile.TemporaryDirectory(prefix="hinagata-bench-") as temporary:
        workspace = pathlib.Path(temporary)
        result = {"metadata": metadata, "small": small_cases(workspace, cli), "bulk": bulk_cases(workspace, bench)}
        result["lifecycle"] = lifecycle_cases(workspace, cli)
        result["concurrency"] = concurrent_cases(workspace, concurrent)
        result["spare_clones"] = spare_clone_cases(workspace, cli)
    small_gate = all(case["setup"]["median"] < 250 and case["setup"]["p95_nearest_rank"] < 500 for case in result["small"]["cases"].values())
    copy_ratios = {rows: case["hinagata"]["copy"]["median"] / case["psql"]["copy"]["median"] for rows, case in result["bulk"].items()}
    copy_gate = all(ratio <= 1.25 for ratio in copy_ratios.values())
    memory_delta = None
    if "100000" in result["bulk"] and "1000000" in result["bulk"]:
        small_rss = statistics.median(sample["rss_bytes"] for sample in result["bulk"]["100000"]["hinagata"]["samples"])
        large_rss = statistics.median(sample["rss_bytes"] for sample in result["bulk"]["1000000"]["hinagata"]["samples"])
        memory_delta = large_rss - small_rss
    memory_gate = memory_delta is not None and memory_delta <= 64 * 1024 * 1024
    result["gates"] = {"small_setup": small_gate, "copy_ratio": copy_gate, "copy_ratios": copy_ratios, "incremental_client_rss_bytes": memory_delta, "incremental_client_rss": memory_gate, "valid_sample_counts": SMALL_REPS >= 30 and BULK_REPS >= 5}
    (ARTIFACT / "results.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    summary_text = render_summary(result)
    (ARTIFACT / "summary.txt").write_text(summary_text)
    print(f"Benchmark results: {ARTIFACT / 'results.json'}")
    print(summary_text, end="")
    if result["gates"]["valid_sample_counts"] and not all((small_gate, copy_gate, memory_gate)):
        raise RuntimeError(f"reference-machine performance gate missed: {result['gates']}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise
