"""Local-dev-only entrypoint.

In production this handler runs on an EventBridge scheduled rule; locally
there's no scheduler, so this just calls it in a loop on a fixed interval.
Not part of the deployed Lambda.
"""
import logging
import time

from common_py import config

from handler import handler

logging.basicConfig(level=logging.INFO, format="%(asctime)s embedding-job %(message)s")
log = logging.getLogger("embedding-job.local_runner")

if __name__ == "__main__":
    log.info("polling every %ss (local stand-in for a scheduled invocation)", config.EMBEDDING_POLL_INTERVAL_S)
    while True:
        handler({}, None)
        time.sleep(config.EMBEDDING_POLL_INTERVAL_S)
