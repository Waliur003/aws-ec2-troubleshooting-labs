#!/usr/bin/env python3

import multiprocessing as mp
import os
import time
import signal

DURATION_SECONDS = 360
WORKERS = min(os.cpu_count() or 1, 2)


def cpu_worker(deadline):
    value = 1

    while time.monotonic() < deadline:
        value = ((value * 1103515245) + 12345) & 0x7FFFFFFF


def main():
    deadline = time.monotonic() + DURATION_SECONDS
    processes = []

    print(
        f"INC-EC2-008: Starting {WORKERS} CPU workers",
        flush=True
    )

    try:
        for _ in range(WORKERS):
            process = mp.Process(
                target=cpu_worker,
                args=(deadline,)
            )
            process.start()
            processes.append(process)

        for process in processes:
            process.join()

    except KeyboardInterrupt:
        print("Interrupted; stopping CPU workers", flush=True)

    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()

        for process in processes:
            process.join(timeout=5)

        print("INC-EC2-008: CPU workload stopped", flush=True)


if __name__ == "__main__":
    main()
