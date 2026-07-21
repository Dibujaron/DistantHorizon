"""M1 decision-gate benchmark for the Distant Horizon server.

Connects N real clients to the server (each logs in as `bench_N`, so each
owns one player ship), receives 15 Hz snapshots for a configurable
duration, then queries server-side tick statistics and prints a PASS/FAIL
report.

PASS requires:
  * every client achieved >= --min-rate snapshots/s (default 14),
  * every snapshot parsed and contained exactly N ships (one per logged-in
    client -- M1 has no fake ships, unlike M0's fixed 500),
  * snapshot ticks strictly increased,
  * server tick p99 < --budget-ms (default 5.0 ms).

Usage:
    python benchmark.py                 # full 60 s run, 20 clients
    python benchmark.py --duration 10   # quick smoke run
"""

from __future__ import annotations

import argparse
import asyncio
import statistics
import sys
import time
from dataclasses import dataclass, field

from dh_client import DHClient, ProtocolError, validate_snapshot


@dataclass
class ClientResult:
    name: str
    snapshots: int = 0
    errors: list = field(default_factory=list)
    intervals: list = field(default_factory=list)  # seconds between snapshots
    elapsed: float = 0.0
    last_tick: int = -1

    @property
    def rate(self) -> float:
        return self.snapshots / self.elapsed if self.elapsed > 0 else 0.0

    @property
    def jitter_ms(self) -> float:
        """Standard deviation of inter-snapshot intervals, in ms."""
        if len(self.intervals) < 2:
            return 0.0
        return statistics.pstdev(self.intervals) * 1000.0

    @property
    def max_gap_ms(self) -> float:
        return max(self.intervals) * 1000.0 if self.intervals else 0.0


async def run_client(client: DHClient, duration: float, expected_ships: int) -> ClientResult:
    """Receive snapshots for `duration` seconds. Leaves the connection open."""
    result = ClientResult(name=client.name)
    start = time.monotonic()
    deadline = start + duration
    prev_arrival = None
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            message = await asyncio.wait_for(client.recv(), timeout=remaining)
        except TimeoutError:
            break
        except Exception as e:  # connection drop, protocol violation, ...
            result.errors.append(f"recv failed: {e}")
            break
        arrival = time.monotonic()
        try:
            validate_snapshot(message, expected_ships)
            tick = message["tick"]
            if tick <= result.last_tick:
                raise ProtocolError(f"tick went backwards: {result.last_tick} -> {tick}")
            result.last_tick = tick
        except ProtocolError as e:
            result.errors.append(str(e))
            continue
        result.snapshots += 1
        if prev_arrival is not None:
            result.intervals.append(arrival - prev_arrival)
        prev_arrival = arrival
    result.elapsed = time.monotonic() - start
    return result


async def check_server_fresh(args: argparse.Namespace) -> str | None:
    """Return an error string if the server looks stale, else None.

    The server's tick stats are cumulative since it started, and a lingering
    server may have other clients attached (a Godot client, an earlier
    benchmark), so results against it are polluted. A fresh server has only
    been ticking for however long it took us to type the two commands.

    The probe connection deliberately does not log in, so it never owns a
    ship and is never counted in the server's `clients` stat (which, since
    M1, only counts logged-in clients -- see sim.gleam's AddShip) -- no
    "minus our probe" adjustment needed.
    """
    probe = DHClient(args.url, name="probe")
    await probe.connect()
    try:
        stats = await asyncio.wait_for(probe.get_stats(), timeout=5.0)
    finally:
        await probe.close()
    age = stats.get("ticks", 0) / 60.0  # server ticks at 60 Hz
    if age > args.max_server_age:
        return (
            f"server has already been running ~{age:.0f} s "
            f"(limit {args.max_server_age:.0f} s) - its cumulative stats would "
            "pollute this run; restart the server or pass --max-server-age 0"
        )
    others = stats.get("clients", 0)
    if others > 0:
        return f"server already has {others} other client(s) connected"
    return None


async def run_benchmark(args: argparse.Namespace) -> int:
    if args.max_server_age > 0:
        try:
            stale = await check_server_fresh(args)
        except Exception as e:
            print(f"FAIL: could not probe server at {args.url}: {e}")
            return 1
        if stale:
            print(f"FAIL: {stale}")
            return 1

    print(f"connecting {args.clients} clients to {args.url} ...")
    clients = [DHClient(args.url, name=f"c{i:02d}") for i in range(args.clients)]
    try:
        await asyncio.gather(*(c.connect() for c in clients))
    except Exception as e:
        print(f"FAIL: could not connect: {e}")
        return 1

    print(f"logging in {args.clients} clients ...")
    try:
        await asyncio.gather(
            *(
                asyncio.wait_for(c.login(f"bench_{i}", "benchmark"), timeout=5.0)
                for i, c in enumerate(clients)
            )
        )
    except Exception as e:
        print(f"FAIL: login failed: {e}")
        await asyncio.gather(*(c.close() for c in clients), return_exceptions=True)
        return 1

    # M1 has no fake ships: one logged-in client == one ship, so the
    # expected ship count per snapshot is just the client count.
    expected_ships = args.clients

    print(f"receiving snapshots for {args.duration:.0f} s ...")
    results = await asyncio.gather(
        *(run_client(c, args.duration, expected_ships) for c in clients)
    )

    # Query server stats while all clients are still connected, so the
    # server-reported client count reflects the benchmark load.
    try:
        stats = await asyncio.wait_for(clients[0].get_stats(), timeout=5.0)
    except Exception as e:
        print(f"FAIL: get_stats failed: {e}")
        stats = None
    finally:
        await asyncio.gather(*(c.close() for c in clients), return_exceptions=True)

    return report(args, results, stats)


def report(args, results: list[ClientResult], stats: dict | None) -> int:
    failures = []

    print()
    print("=== per-client snapshot rates ===")
    print(f"{'client':>7} {'snaps':>6} {'rate/s':>7} {'jitter ms':>10} {'max gap ms':>11} {'errors':>7}")
    for r in results:
        print(
            f"{r.name:>7} {r.snapshots:>6} {r.rate:>7.2f} "
            f"{r.jitter_ms:>10.1f} {r.max_gap_ms:>11.1f} {len(r.errors):>7}"
        )
        if r.rate < args.min_rate:
            failures.append(f"{r.name}: rate {r.rate:.2f}/s < {args.min_rate}/s")
        for e in r.errors[:5]:
            failures.append(f"{r.name}: {e}")

    rates = [r.rate for r in results]
    if rates:
        print(f"\nrate min/mean/max: {min(rates):.2f} / {statistics.mean(rates):.2f} / {max(rates):.2f} snapshots/s (target 15, accept >= {args.min_rate})")

    print("\n=== server tick stats ===")
    if stats is None:
        failures.append("no stats response from server")
    else:
        tick_ms = stats.get("tick_ms", {})
        print(f"ticks simulated: {stats.get('ticks')}   connected clients (server view): {stats.get('clients')}")
        for key in ("p50", "p95", "p99", "max"):
            value = tick_ms.get(key)
            verdict = ""
            if isinstance(value, (int, float)):
                verdict = "OK" if value < args.budget_ms else "OVER BUDGET"
                print(f"  tick {key:>4}: {value:8.3f} ms   (budget {args.budget_ms} ms) {verdict}")
            else:
                failures.append(f"stats missing tick_ms.{key}")
        p99 = tick_ms.get("p99")
        if not isinstance(p99, (int, float)):
            failures.append("stats missing tick_ms.p99")
        elif p99 >= args.budget_ms:
            failures.append(f"server tick p99 {p99:.3f} ms >= budget {args.budget_ms} ms")
        if stats.get("clients") != args.clients:
            failures.append(
                f"server saw {stats.get('clients')} clients, expected {args.clients}"
            )

    print()
    if failures:
        print("RESULT: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(
        f"RESULT: PASS - {len(results)} clients at >= {args.min_rate} snapshots/s, "
        f"server tick p99 under {args.budget_ms} ms"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # Deliberately hardcoded to the server's default port rather than
    # following DH_PORT: this benchmark targets a manually-run server (dev
    # or "production"), not the harness's dedicated test port. Pass --url
    # explicitly to target a server started with a non-default DH_PORT.
    parser.add_argument("--url", default="ws://127.0.0.1:8484/ws")
    parser.add_argument("--clients", type=int, default=20)
    parser.add_argument("--duration", type=float, default=60.0, help="seconds to receive snapshots")
    parser.add_argument("--min-rate", type=float, default=14.0, help="minimum snapshots/s per client")
    parser.add_argument("--budget-ms", type=float, default=5.0, help="server tick p99 budget")
    parser.add_argument(
        "--max-server-age", type=float, default=30.0,
        help="fail if the server has been up longer than this many seconds "
        "or has other clients attached (0 disables the freshness check)",
    )
    args = parser.parse_args()
    return asyncio.run(run_benchmark(args))


if __name__ == "__main__":
    sys.exit(main())
