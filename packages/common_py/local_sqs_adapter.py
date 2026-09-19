"""Local-dev-only adapter: turns an SQS queue into invocations of a Lambda handler.

In real AWS, EventBridge invokes transcriber-job directly as a rule target
(see docs/architecture.md) -- no queue involved. Locally, nothing can
invoke a plain container the way EventBridge invokes a managed Lambda, so
transcriber-job's `local_runner.py` puts an SQS queue as the EventBridge
rule's target instead (see docker/localstack/init/ready.d/01-init-aws.sh)
and this adapter polls it, calling the *same* `handler(event, context)`
function that would run in Lambda for each message.

This keeps handler.py identical to what ships to AWS; only this adapter
is local-only.
"""
import json
import logging
import time
from typing import Callable

from . import aws_clients

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")


def _get_queue_url(sqs, queue_name: str, retries: int = 20, delay_s: float = 3.0) -> str:
    last_error = None
    for _ in range(retries):
        try:
            return sqs.get_queue_url(QueueName=queue_name)["QueueUrl"]
        except sqs.exceptions.QueueDoesNotExist as exc:
            last_error = exc
            time.sleep(delay_s)
    raise RuntimeError(f"queue '{queue_name}' never appeared after {retries} attempts") from last_error


def run(queue_name: str, handler: Callable[[dict, None], None]) -> None:
    """Poll `queue_name` forever, calling `handler(event, None)` per message.

    A handler that raises leaves the message on the queue so SQS redelivers
    it, and after the queue's maxReceiveCount is exceeded it lands on the
    DLQ that the LocalStack bootstrap script provisions -- mirroring the
    retry/DLQ semantics described in docs/cost-and-reliability.md.
    """
    log = logging.getLogger(queue_name)
    sqs = aws_clients.sqs_client()
    queue_url = _get_queue_url(sqs, queue_name)
    log.info("polling %s", queue_url)

    while True:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=5,
            WaitTimeSeconds=10,
            VisibilityTimeout=30,
        )
        for message in response.get("Messages", []):
            receipt_handle = message["ReceiptHandle"]
            try:
                event = json.loads(message["Body"])
                handler(event, None)
                sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            except Exception:  # noqa: BLE001 - deliberately broad: leave message for redelivery/DLQ
                log.exception("failed to process message, leaving for redelivery")
