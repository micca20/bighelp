"""Private, in-memory credential handoff to a serial native probe.

The FIFO contains no on-disk credential bytes. Its directory and permissions
restrict access to the current user; callers own the temporary directory.
"""
import errno
import json
import os
import threading


class PrivateProbeConfiguration:
    def __init__(self, directory, values):
        self.path = directory / "probe-config.pipe"
        self._payload = json.dumps(values).encode()
        if len(self._payload) > 4096:
            raise ValueError("Probe configuration exceeds one atomic pipe write")
        self._stop = threading.Event()
        self._thread = None

    def __enter__(self):
        os.mkfifo(self.path, 0o600)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self.path

    def _serve(self):
        while not self._stop.is_set():
            descriptor = None
            try:
                descriptor = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
                written = os.write(descriptor, self._payload)
                if written != len(self._payload):
                    return
            except OSError as error:
                if error.errno not in (errno.ENXIO, errno.EPIPE, errno.EAGAIN):
                    return
            finally:
                if descriptor is not None:
                    os.close(descriptor)
            # Consumers are serial and close after one complete JSON document.
            self._stop.wait(0.1)

    def __exit__(self, *_):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1)
        self._payload = b""
        self.path.unlink(missing_ok=True)
