"""boto3 clients pre-wired for local dev (LocalStack) or real AWS.

When AWS_ENDPOINT_URL is unset (real deployments), boto3 falls back to its
normal endpoint resolution and credential chain untouched.
"""
import boto3

from . import config


def _client(service_name: str):
    kwargs = {"region_name": config.AWS_REGION}
    if config.AWS_ENDPOINT_URL:
        kwargs["endpoint_url"] = config.AWS_ENDPOINT_URL
        # LocalStack does not validate credentials; any static values work.
        kwargs["aws_access_key_id"] = "test"
        kwargs["aws_secret_access_key"] = "test"
    return boto3.client(service_name, **kwargs)


def sqs_client():
    return _client("sqs")
