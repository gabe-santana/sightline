# Semantic-search store for transcript-segment (and eventually visual-frame)
# embeddings -- replaces Amazon OpenSearch Service (see docs/architecture.md
# for why). Verified directly against this account before committing to it:
# the service is live in this region, has a VPC interface endpoint (see
# vpc.tf), and a real put/query round-trip with a metadata filter (e.g.
# video_id) returns exactly the filtered nearest-neighbor result RAG
# retrieval needs -- confirmed with the AWS CLI, not just documentation.
#
# Unlike OpenSearch, a vector bucket/index has no VPC footprint of its own
# (no ENIs, no subnets, no per-node cost) -- it's an S3-adjacent API
# reached the same way S3 itself is reached (IAM + a VPC endpoint), which
# is also why the fixed monthly cost floor from infra/README.md drops by
# the OpenSearch line entirely.

resource "aws_s3vectors_vector_bucket" "main" {
  vector_bucket_name = "${local.name}-vectors"
  force_destroy      = true # same reasoning as aws_s3_bucket.videos in s3.tf

  encryption_configuration {
    sse_type = "AES256"
  }
}

# One index per embedding "kind". Currently just transcript segments --
# there is no visual-frame sampling stage in this pipeline (see
# docs/architecture.md); a second index could be added the same way if
# one is introduced later.
resource "aws_s3vectors_index" "transcript_segments" {
  vector_bucket_name = aws_s3vectors_vector_bucket.main.vector_bucket_name
  index_name         = "transcript-segments"

  data_type       = "float32"
  dimension       = var.embedding_dimension
  distance_metric = var.embedding_distance_metric

  metadata_configuration {
    # Every other key (video_id, timestamp_s, segment_id, ...) stays
    # filterable, which is what lets the query agent scope a search to a
    # specific video or date range. The transcript text itself is bulky
    # and never something a query filters *on*, so it's excluded to keep
    # filterable metadata lean.
    non_filterable_metadata_keys = ["text"]
  }
}
