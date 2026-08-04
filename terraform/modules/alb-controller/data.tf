# CloudFront's origin-facing address ranges (AWS-managed prefix list, updated
# by AWS as edges change) — feeds the Origin cloaking SG in main.tf.
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  count = var.cloudfront_only_sg_name != "" ? 1 : 0

  name = "com.amazonaws.global.cloudfront.origin-facing"
}
