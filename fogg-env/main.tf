variable "org_bucket" {}
variable "org_workspace" {}
variable "org_key" {}
variable "org_region" {}

variable "reg_key" {}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "eu_west_1"
  region = "eu-west-1"
}

locals {
  private_zone_name = "${signum(length(var.env_zone)) == 1 ? var.env_zone : var.env_name}.${signum(length(var.env_domain_name)) == 1 ? var.env_domain_name : data.terraform_remote_state.org.domain_name}"
}

data "terraform_remote_state" "org" {
  backend   = "s3"
  workspace = "${var.org_workspace}"

  config {
    bucket         = "${var.org_bucket}"
    key            = "${var.org_key}"
    region         = "${var.org_region}"
    dynamodb_table = "terraform_state_lock"
  }
}

data "terraform_remote_state" "reg" {
  backend   = "s3"
  workspace = "${var.region}"

  config {
    bucket         = "${var.org_bucket}"
    key            = "${var.reg_key}"
    region         = "${var.org_region}"
    dynamodb_table = "terraform_state_lock"
  }
}

data "aws_vpc" "current" {
  id = "${aws_vpc.env.id}"
}

data "aws_availability_zones" "azs" {}

data "aws_partition" "current" {}

resource "aws_vpc" "env" {
  cidr_block                       = "${var.cidr}"
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = true

  tags {
    "Name"      = "${var.env_name}"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_security_group" "env" {
  name        = "${var.env_name}"
  description = "Environment ${var.env_name}"
  vpc_id      = "${aws_vpc.env.id}"

  tags {
    "Name"      = "${var.env_name}"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_security_group_rule" "allow_zerotier" {
  type              = "ingress"
  from_port         = 9993
  to_port           = 9993
  protocol          = "udp"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = "${aws_security_group.env.id}"
  description       = "zerotier inbound"
}

resource "aws_security_group_rule" "env_egress" {
  type              = "egress"
  protocol          = "all"
  from_port         = -1
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = "${aws_security_group.env.id}"
  description       = "env outbound"
}

resource "aws_internet_gateway" "env" {
  vpc_id = "${aws_vpc.env.id}"

  tags {
    "Name"      = "${var.env_name}"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_egress_only_internet_gateway" "env" {
  vpc_id = "${aws_vpc.env.id}"
  count  = 1
}

resource "null_resource" "fake" {
  count = "${var.az_count}"

  triggers {
    meh = ""
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = "${aws_vpc.env.id}"
  availability_zone       = "${element(data.aws_availability_zones.azs.names,count.index)}"
  map_public_ip_on_launch = true
  cidr_block              = "${cidrsubnet(data.aws_vpc.current.cidr_block,var.public_bits,element(var.public_subnets,count.index))}"
  count                   = "${var.az_count}"

  tags {
    "Name"      = "${var.env_name}-public"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
    "Network"   = "public"
  }
}

resource "aws_route" "public" {
  route_table_id         = "${element(aws_route_table.public.*.id,count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.env.id}"
  count                  = "${var.az_count}"
}

resource "aws_route" "public_v6" {
  route_table_id              = "${element(aws_route_table.public.*.id,count.index)}"
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = "${aws_internet_gateway.env.id}"
  count                       = "${var.az_count}"
}

resource "aws_route_table_association" "public" {
  subnet_id      = "${element(aws_subnet.public.*.id,count.index)}"
  route_table_id = "${element(aws_route_table.public.*.id,count.index)}"
  count          = "${var.az_count}"
}

resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.env.id}"
  count  = "${var.az_count}"

  tags {
    "Name"      = "${var.env_name}-public"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
    "Network"   = "public"
  }
}

resource "aws_vpn_gateway_route_propagation" "public" {
  vpn_gateway_id = "${aws_vpn_gateway.env.id}"
  route_table_id = "${element(aws_route_table.public.*.id,count.index)}"
  count          = "${var.az_count*var.want_vgw}"
}

resource "aws_subnet" "private" {
  vpc_id                  = "${aws_vpc.env.id}"
  availability_zone       = "${element(data.aws_availability_zones.azs.names,count.index)}"
  map_public_ip_on_launch = false
  cidr_block              = "${cidrsubnet(data.aws_vpc.current.cidr_block,var.private_bits,element(var.private_subnets,count.index))}"
  count                   = "${var.az_count}"

  tags {
    "Name"      = "${var.env_name}-private"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_route" "private_v6" {
  route_table_id              = "${element(aws_route_table.private.*.id,count.index)}"
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = "${aws_internet_gateway.env.id}"
  count                       = "${var.az_count}"
}

resource "aws_route" "private_nat_eni" {
  route_table_id         = "${element(aws_route_table.private.*.id,count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = "${element(module.nat.interfaces,count.index)}"
  count                  = "${var.az_count*(signum(var.want_nat)-1)*-1}"
}

resource "aws_route_table_association" "private" {
  subnet_id      = "${element(aws_subnet.private.*.id,count.index)}"
  route_table_id = "${element(aws_route_table.private.*.id,count.index)}"
  count          = "${var.az_count}"
}

resource "aws_vpc_endpoint_route_table_association" "s3_private" {
  vpc_endpoint_id = "${aws_vpc_endpoint.s3.id}"
  route_table_id  = "${element(aws_route_table.private.*.id,count.index)}"
  count           = "${var.az_count}"
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_private" {
  vpc_endpoint_id = "${aws_vpc_endpoint.dynamodb.id}"
  route_table_id  = "${element(aws_route_table.private.*.id,count.index)}"
  count           = "${var.az_count}"
}

resource "aws_route_table" "private" {
  vpc_id = "${aws_vpc.env.id}"
  count  = "${var.az_count}"

  tags {
    "Name"      = "${var.env_name}-private"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_vpn_gateway_route_propagation" "private" {
  vpn_gateway_id = "${aws_vpn_gateway.env.id}"
  route_table_id = "${element(aws_route_table.private.*.id,count.index)}"
  count          = "${var.az_count*var.want_vgw}"
}

resource "aws_route53_zone" "private" {
  name   = "${local.private_zone_name}"
  vpc_id = "${aws_vpc.env.id}"

  tags {
    "Name"      = "${var.env_name}"
    "Env"       = "${var.env_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_route53_zone_association" "associates" {
  zone_id = "${element(var.associate_zones,count.index)}"
  vpc_id  = "${aws_vpc.env.id}"
  count   = "${var.associate_count}"
}

module "efs" {
  source   = ".module/fogg-tf/fogg-efs"
  efs_name = "${var.env_name}"
  vpc_id   = "${aws_vpc.env.id}"
  env_name = "${var.env_name}"
  subnets  = ["${aws_subnet.private.*.id}"]
  az_count = "${var.az_count}"
  want_efs = "${var.want_efs}"
}

resource "aws_route53_record" "efs" {
  zone_id = "${aws_route53_zone.private.zone_id}"
  name    = "efs.${local.private_zone_name}"
  type    = "CNAME"
  ttl     = "60"
  records = ["${element(module.efs.efs_dns_names,count.index)}"]
  count   = "${var.want_efs}"
}

resource "aws_cloudwatch_log_group" "flow_log" {
  name = "${var.env_name}-flow-log"
}

data "aws_iam_policy_document" "flow_log" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_log" {
  name               = "${var.env_name}-flow-log"
  assume_role_policy = "${data.aws_iam_policy_document.flow_log.json}"
}

data "aws_iam_policy_document" "flow_log_logs" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "flow_log" {
  name   = "${var.env_name}-flow-log"
  role   = "${aws_iam_role.flow_log.id}"
  policy = "${data.aws_iam_policy_document.flow_log_logs.json}"
}

resource "aws_flow_log" "env" {
  log_group_name = "${aws_cloudwatch_log_group.flow_log.name}"
  iam_role_arn   = "${aws_iam_role.flow_log.arn}"
  vpc_id         = "${aws_vpc.env.id}"
  traffic_type   = "ALL"
}

resource "aws_s3_bucket" "meta" {
  bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-meta"
  acl    = "log-delivery-write"

  versioning {
    enabled = true
  }

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
  }
}

resource "aws_s3_bucket" "s3" {
  bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-s3"
  acl    = "log-delivery-write"

  depends_on = ["aws_s3_bucket.meta"]

  logging {
    target_bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-meta"
    target_prefix = "log/"
  }

  versioning {
    enabled = true
  }

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
  }
}

data "aws_iam_policy_document" "aws_s3_bucket_ses" {
  statement {
    actions = [
      "s3:PutObject",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-ses/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:Referer"
      values   = ["${data.terraform_remote_state.org.aws_account_id}"]
    }
  }
}

resource "aws_s3_bucket" "ses" {
  bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-ses"
  acl    = "private"

  depends_on = ["aws_s3_bucket.s3"]

  logging {
    target_bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-s3"
    target_prefix = "log/"
  }

  versioning {
    enabled = true
  }

  policy = "${data.aws_iam_policy_document.aws_s3_bucket_ses.json}"

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
  }
}

data "aws_iam_policy_document" "aws_s3_bucket_ssm" {
  statement {
    actions = [
      "s3:GetBucketAcl",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-ssm",
    ]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }

  statement {
    actions = [
      "s3:PutObject",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-ssm/*/accountid=${data.terraform_remote_state.org.aws_account_id}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket" "ssm" {
  bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-ssm"
  acl    = "private"

  depends_on = ["aws_s3_bucket.s3"]

  logging {
    target_bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-s3"
    target_prefix = "log/"
  }

  versioning {
    enabled = true
  }

  policy = "${data.aws_iam_policy_document.aws_s3_bucket_ssm.json}"

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
  }
}

resource "aws_s3_bucket" "svc" {
  bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-svc"
  acl    = "private"

  depends_on = ["aws_s3_bucket.s3"]

  logging {
    target_bucket = "b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${var.env_name}-s3"
    target_prefix = "log/"
  }

  versioning {
    enabled = true
  }

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
  }
}

resource "aws_kms_key" "env" {
  description         = "Environment ${var.env_name}"
  enable_key_rotation = false

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
    "Name"      = "${var.env_name}"
  }

  count = "${var.want_kms}"
}

resource "aws_kms_alias" "env" {
  name          = "alias/${var.env_name}"
  target_key_id = "${element(coalescelist(aws_kms_key.env.*.id,list(data.terraform_remote_state.reg.kms_key_id)),0)}"
}

data "aws_vpc_endpoint_service" "s3" {
  service = "s3"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = "${aws_vpc.env.id}"
  service_name = "${data.aws_vpc_endpoint_service.s3.service_name}"
}

data "aws_vpc_endpoint_service" "dynamodb" {
  service = "dynamodb"
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = "${aws_vpc.env.id}"
  service_name = "${data.aws_vpc_endpoint_service.dynamodb.service_name}"
}

data "aws_vpc_endpoint_service" "apigateway" {
  service = "execute-api"
}

resource "aws_vpc_endpoint" "apigateway" {
  vpc_id              = "${aws_vpc.env.id}"
  service_name        = "${data.aws_vpc_endpoint_service.apigateway.service_name}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  security_group_ids = [
    "${aws_security_group.env.id}",
  ]

  subnet_ids = ["${element(aws_subnet.private.*.id,0)}"]

  count = "${var.want_private_api}"
}

resource "aws_default_vpc_dhcp_options" "default" {
  tags {
    Name = "default"
  }
}

resource "aws_vpc_dhcp_options" "env" {
  domain_name_servers = ["${aws_default_vpc_dhcp_options.default.domain_name_servers}"]
  domain_name         = "${aws_route53_zone.private.name}"

  tags {
    "ManagedBy" = "terraform"
    "Env"       = "${var.env_name}"
    "Name"      = "${var.env_name}"
  }
}

resource "aws_vpc_dhcp_options_association" "env" {
  vpc_id          = "${aws_vpc.env.id}"
  dhcp_options_id = "${aws_vpc_dhcp_options.env.id}"
}

resource "aws_codecommit_repository" "env" {
  repository_name = "${var.env_name}"
  description     = "Repo for ${var.env_name} env"
}

resource "aws_ssm_parameter" "fogg_env" {
  name  = "${var.env_name}.fogg_env"
  type  = "String"
  value = "${var.env_name}"
}

resource "aws_ssm_parameter" "fogg_env_sg" {
  name  = "${var.env_name}.fogg_env_sg"
  type  = "String"
  value = "${aws_security_group.env.id}"
}

data "aws_route53_zone" "public" {
  name         = "${data.terraform_remote_state.org.domain_name}"
  private_zone = false
}

data "aws_acm_certificate" "us_east_1" {
  provider    = "aws.us_east_1"
  domain      = "*.${data.terraform_remote_state.org.domain_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "env" {
  domain      = "*.${data.terraform_remote_state.org.domain_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_service_discovery_private_dns_namespace" "env" {
  count = "${var.want_sd}"
  name  = "prv-${local.private_zone_name}"
  vpc   = "${data.aws_vpc.current.id}"
}

resource "aws_service_discovery_public_dns_namespace" "env" {
  count = "${var.want_sd}"
  name  = "pub-${local.private_zone_name}"
}

resource "aws_ssm_maintenance_window" "every_hour" {
  name                       = "${var.env_name}-every-hour"
  schedule                   = "cron(0 0 */1 * * ? *)"
  duration                   = 1
  cutoff                     = 0
  allow_unassociated_targets = true
}

resource "aws_ssm_maintenance_window_target" "env" {
  window_id     = "${aws_ssm_maintenance_window.every_hour.id}"
  resource_type = "INSTANCE"

  targets {
    key    = "tag:Env"
    values = ["${var.env_name}"]
  }
}

resource "aws_ssm_maintenance_window_task" "patch_scan" {
  window_id        = "${aws_ssm_maintenance_window.every_hour.id}"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  priority         = 1
  service_role_arn = "${data.terraform_remote_state.org.ssm_role}"
  max_concurrency  = "2"
  max_errors       = "1"

  targets {
    key    = "WindowTargetIds"
    values = ["${aws_ssm_maintenance_window_target.env.id}"]
  }

  task_parameters {
    name   = "Operation"
    values = ["Scan"]
  }

  logging_info {
    s3_bucket_name   = "${aws_s3_bucket.ssm.bucket}"
    s3_region        = "${aws_s3_bucket.ssm.region}"
    s3_bucket_prefix = "patch_scan"
  }
}

resource "aws_ssm_maintenance_window_task" "ps" {
  window_id        = "${aws_ssm_maintenance_window.every_hour.id}"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunShellScript"
  priority         = 1
  service_role_arn = "${data.terraform_remote_state.org.ssm_role}"
  max_concurrency  = "2"
  max_errors       = "1"

  targets {
    key    = "WindowTargetIds"
    values = ["${aws_ssm_maintenance_window_target.env.id}"]
  }

  task_parameters {
    name   = "commands"
    values = ["ps axuf", "df -klh", "uname -a"]
  }

  logging_info {
    s3_bucket_name   = "${aws_s3_bucket.ssm.bucket}"
    s3_region        = "${aws_s3_bucket.ssm.region}"
    s3_bucket_prefix = "ps"
  }
}

resource "aws_ssm_association" "GatherSoftwareInventory" {
  name             = "AWS-GatherSoftwareInventory"
  association_name = "${var.env_name}-gather-software-inventory"

  schedule_expression = "cron(0 0 */1 * * ? *)"

  targets {
    key    = "tag:Env"
    values = ["${var.env_name}"]
  }

  output_location {
    s3_bucket_name = "${aws_s3_bucket.ssm.bucket}"
    s3_key_prefix  = "gather-software-inventory"
  }
}
