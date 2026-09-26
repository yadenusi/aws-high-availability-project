variable "project_name" {
  description = "Short lowercase name used as the prefix for every resource."
  type        = string
  default     = "ecommerce-ha"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 3 to 21 characters of lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "project_code" {
  description = "Capstone project code, used so each project gets its own state bucket."
  type        = string
  default     = "p01"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Person responsible for these resources, applied as a tag."
  type        = string
  default     = "Yusuf Adenusi"
}

variable "aws_region" {
  description = "Region that holds the state bucket. Should match the main stack region."
  type        = string
  default     = "us-east-2"
}

variable "state_key" {
  description = "Object key of the main stack state file inside the bucket."
  type        = string
  default     = "project-01-ha-ecommerce/terraform.tfstate"
}

variable "noncurrent_version_retention_days" {
  description = "How long old versions of the state file are kept before S3 expires them."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 30
    error_message = "Keep at least 30 days of state history so a bad apply can be rolled back."
  }
}
