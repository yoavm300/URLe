resource "aws_ecr_repository" "repository" {
  name = var.name

  # SemVer discipline: a published X.Y.Z can never be overwritten.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "lifecycle" {
  repository = aws_ecr_repository.repository.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Published for discoverability (chart values, cross-repo automation);
# plain String — a repository URL is not a secret.
resource "aws_ssm_parameter" "repository_url" {
  count = var.ssm_parameter_prefix != "" ? 1 : 0

  name      = "${var.ssm_parameter_prefix}/ecr/${var.name}/repository-url"
  type      = "String"
  value     = aws_ecr_repository.repository.repository_url
  overwrite = true
  tags      = var.tags
}
