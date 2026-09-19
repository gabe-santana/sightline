# Build context is the repository root (see docker/docker-compose.yml) so
# this can pull in packages/common_py, shared by every Python job.
# NOTE: this Dockerfile is for local dev only. The real deployment artifact
# is handler.py packaged as a plain Lambda zip/image (see infra/).
FROM python:3.12-slim
WORKDIR /app
COPY src/embedding-job/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY packages/common_py ./common_py
COPY src/embedding-job/handler.py src/embedding-job/local_runner.py ./
CMD ["python", "local_runner.py"]
