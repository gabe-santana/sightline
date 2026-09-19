"""Local-dev-only entrypoint -- see packages/common_py/local_sqs_adapter.py.

Not part of the deployed Lambda; docker-compose runs this instead of a real
EventBridge invocation.
"""
from common_py import config
from common_py.local_sqs_adapter import run

from handler import handler

if __name__ == "__main__":
    run(config.TRANSCRIBER_QUEUE_NAME, handler)
