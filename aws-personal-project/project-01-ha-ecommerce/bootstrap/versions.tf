terraform {
  # S3 native state locking (use_lockfile) is generally available from 1.11.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # The bootstrap stack keeps its own state locally on purpose. It only creates
  # the bucket and key that every later run of the main stack depends on, so it
  # cannot store its state in a bucket that does not exist yet.
}
