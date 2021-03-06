variable "org_bucket" {}
variable "org_workspace" {}
variable "org_key" {}
variable "org_region" {}

variable "reg_key" {}
variable "env_key" {}
variable "app_key" {}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_partition" "current" {}

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

data "terraform_remote_state" "env" {
  backend   = "s3"
  workspace = "${terraform.workspace}"

  config {
    bucket         = "${var.org_bucket}"
    key            = "${var.env_key}"
    region         = "${var.org_region}"
    dynamodb_table = "terraform_state_lock"
  }
}

data "terraform_remote_state" "app" {
  backend   = "s3"
  workspace = "${terraform.workspace}"

  config {
    bucket         = "${var.org_bucket}"
    key            = "${var.app_key}"
    region         = "${var.org_region}"
    dynamodb_table = "terraform_state_lock"
  }
}

data "aws_availability_zones" "azs" {}
data "aws_caller_identity" "current" {}

data "aws_vpc" "current" {
  id = "${data.terraform_remote_state.env.vpc_id}"
}

resource "aws_security_group" "service" {
  name        = "${local.service_name}"
  description = "Service ${data.terraform_remote_state.app.app_name}-${var.service_name}"
  vpc_id      = "${data.aws_vpc.current.id}"

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_security_group" "cache" {
  name        = "${local.service_name}-cache"
  description = "Cache ${data.terraform_remote_state.app.app_name}-${var.service_name}"
  vpc_id      = "${data.aws_vpc.current.id}"

  tags {
    "Name"      = "${local.service_name}-cache"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-cache"
    "ManagedBy" = "terraform"
  }

  count = "${var.want_elasticache}"
}

resource "aws_security_group" "db" {
  name        = "${local.service_name}-db"
  description = "Database ${data.terraform_remote_state.app.app_name}-${var.service_name}"
  vpc_id      = "${data.aws_vpc.current.id}"

  tags {
    "Name"      = "${local.service_name}-db"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-db"
    "ManagedBy" = "terraform"
  }

  count = "${var.want_aurora}"
}

resource "aws_subnet" "service" {
  vpc_id = "${data.aws_vpc.current.id}"

  availability_zone = "${element(data.aws_availability_zones.azs.names,count.index)}"

  cidr_block                      = "${cidrsubnet(data.aws_vpc.current.cidr_block,var.service_bits,element(split(" ",lookup(var.service,var.service_name,"")),count.index))}"
  map_public_ip_on_launch         = "${signum(var.public_network) == 1 ? "true" : "false"}"
  assign_ipv6_address_on_creation = false

  count = "${var.want_subnets*var.az_count*(var.want_ipv6 - 1)*-1}"

  lifecycle {
    create_before_destroy = true
  }

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_subnet" "service_v6" {
  vpc_id = "${data.aws_vpc.current.id}"

  availability_zone = "${element(data.aws_availability_zones.azs.names,count.index)}"

  cidr_block                      = "${cidrsubnet(data.aws_vpc.current.cidr_block,var.service_bits,element(split(" ",lookup(var.service,var.service_name,"")),count.index))}"
  ipv6_cidr_block                 = "${cidrsubnet(data.aws_vpc.current.ipv6_cidr_block,var.ipv6_service_bits,element(split(" ",lookup(var.ipv6_service,var.service_name,"")),count.index))}"
  map_public_ip_on_launch         = "${signum(var.public_network) == 1 ? "true" : "false"}"
  assign_ipv6_address_on_creation = true

  count = "${var.want_subnets*var.az_count*var.want_ipv6}"

  lifecycle {
    create_before_destroy = true
  }

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_network_interface" "service" {
  subnet_id       = "${element(compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id)),count.index)}"
  security_groups = ["${data.terraform_remote_state.env.sg_env}", "${data.terraform_remote_state.app.app_sg}", "${aws_security_group.service.id}"]
  count           = "${var.want_subnets*var.az_count*var.want_subnets}"

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_route_table" "service" {
  vpc_id = "${data.aws_vpc.current.id}"
  count  = "${var.want_routes*var.want_subnets*var.az_count*(signum(var.public_network)-1)*-1}"

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_vpn_gateway_route_propagation" "service" {
  vpn_gateway_id = "${data.terraform_remote_state.env.vgw_id}"
  route_table_id = "${element(aws_route_table.service.*.id,count.index)}"
  count          = "${var.want_routes*var.want_subnets*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_route" "service_interface_nat" {
  route_table_id         = "${element(aws_route_table.service.*.id,count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = "${element(data.terraform_remote_state.env.nat_interfaces,count.index)}"
  count                  = "${var.want_routes*var.want_subnets*var.want_nat_interface*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_route" "service_interface_vpn" {
  route_table_id         = "${element(aws_route_table.service.*.id,count.index)}"
  destination_cidr_block = "${data.terraform_remote_state.env.vpn_cidr}"
  network_interface_id   = "${element(data.terraform_remote_state.env.vpn_interfaces,count.index)}"
  count                  = "${var.want_routes*var.want_subnets*var.want_vpn*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_route" "service_v6" {
  route_table_id              = "${element(aws_route_table.service.*.id,count.index)}"
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = "${data.terraform_remote_state.env.igw_id}"
  count                       = "${var.want_routes*var.want_subnets*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_route_table_association" "service" {
  subnet_id      = "${element(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id),count.index)}"
  route_table_id = "${element(aws_route_table.service.*.id,count.index)}"
  count          = "${var.want_routes*var.want_subnets*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_route_table_association" "service_env" {
  subnet_id      = "${element(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id),count.index)}"
  route_table_id = "${element(data.terraform_remote_state.env.route_table_private,count.index)}"
  count          = "${(signum(var.want_routes)-1)*-1*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_vpc_endpoint_route_table_association" "s3_service" {
  vpc_endpoint_id = "${data.terraform_remote_state.env.s3_endpoint_id}"
  route_table_id  = "${element(aws_route_table.service.*.id,count.index)}"
  count           = "${var.want_routes*var.want_subnets*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_service" {
  vpc_endpoint_id = "${data.terraform_remote_state.env.dynamodb_endpoint_id}"
  route_table_id  = "${element(aws_route_table.service.*.id,count.index)}"
  count           = "${var.want_routes*var.want_subnets*var.az_count*(signum(var.public_network)-1)*-1}"
}

resource "aws_route_table" "service_public" {
  vpc_id = "${data.aws_vpc.current.id}"
  count  = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
    "Network"   = "public"
  }
}

resource "aws_vpn_gateway_route_propagation" "service_public" {
  vpn_gateway_id = "${data.terraform_remote_state.env.vgw_id}"
  route_table_id = "${element(aws_route_table.service_public.*.id,count.index)}"
  count          = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"
}

resource "aws_route" "service_public" {
  route_table_id         = "${element(aws_route_table.service_public.*.id,count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${data.terraform_remote_state.env.igw_id}"
  count                  = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"
}

resource "aws_route" "service_public_interface_vpn" {
  route_table_id         = "${element(aws_route_table.service_public.*.id,count.index)}"
  destination_cidr_block = "${data.terraform_remote_state.env.vpn_cidr}"
  network_interface_id   = "${element(data.terraform_remote_state.env.vpn_interfaces,count.index)}"
  count                  = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)*var.want_vpn}"
}

resource "aws_route" "service_public_v6" {
  route_table_id              = "${element(aws_route_table.service_public.*.id,count.index)}"
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = "${data.terraform_remote_state.env.igw_id}"
  count                       = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"
}

resource "aws_route_table_association" "service_public" {
  subnet_id      = "${element(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id),count.index)}"
  route_table_id = "${element(aws_route_table.service_public.*.id,count.index)}"
  count          = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"
}

resource "aws_route_table_association" "service_public_env" {
  subnet_id      = "${element(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id),count.index)}"
  route_table_id = "${element(data.terraform_remote_state.env.route_table_public,count.index)}"
  count          = "${(signum(var.want_routes)-1)*-1*var.az_count*signum(var.public_network)}"
}

resource "aws_vpc_endpoint_route_table_association" "s3_service_public" {
  vpc_endpoint_id = "${data.terraform_remote_state.env.s3_endpoint_id}"
  route_table_id  = "${element(aws_route_table.service_public.*.id,count.index)}"
  count           = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_service_public" {
  vpc_endpoint_id = "${data.terraform_remote_state.env.dynamodb_endpoint_id}"
  route_table_id  = "${element(aws_route_table.service_public.*.id,count.index)}"
  count           = "${var.want_routes*var.want_subnets*var.az_count*signum(var.public_network)}"
}

data "aws_iam_policy_document" "service" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "svc" {
  statement {
    actions = [
      "s3:*",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${data.terraform_remote_state.env.env_name}-svc/&{aws:userid}",
      "arn:${data.aws_partition.current.partition}:s3:::b-${format("%.8s",sha1(data.terraform_remote_state.org.aws_account_id))}-${data.terraform_remote_state.env.env_name}-svc/&{aws:userid}/*",
    ]
  }
}

resource "aws_iam_policy" "svc" {
  name        = "${local.service_name}-svc"
  description = "${local.service_name}-svc"
  policy      = "${data.aws_iam_policy_document.svc.json}"
}

resource "aws_iam_role" "service" {
  name               = "${local.service_name}"
  assume_role_policy = "${data.aws_iam_policy_document.service.json}"
}

resource "aws_iam_role_policy_attachment" "svc" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "${aws_iam_policy.svc.arn}"
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerServiceforEC2Role" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerServiceRole" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

resource "aws_iam_role_policy_attachment" "AmazonEC2RoleforSSM" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_role_policy_attachment" "AWSLambdaExecute" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/AWSLambdaExecute"
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "AWSCodeCommitReadOnly" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeCommitReadOnly"
}

resource "aws_iam_role_policy_attachment" "AmazonSSMReadOnlyAccess" {
  role       = "${aws_iam_role.service.name}"
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

resource "aws_iam_instance_profile" "service" {
  name = "${local.service_name}"
  role = "${aws_iam_role.service.name}"
}

data "aws_iam_policy_document" "fargate" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "fargate" {
  name               = "${local.service_name}-fargate"
  assume_role_policy = "${data.aws_iam_policy_document.fargate.json}"
}

resource "aws_iam_role_policy_attachment" "AmazonECSTaskExecutionRolePolicy" {
  role       = "${aws_iam_role.fargate.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "template_file" "user_data_service" {
  template = "${file(var.user_data)}"

  vars {
    vpc_cidr         = "${data.aws_vpc.current.cidr_block}"
    env              = "${data.terraform_remote_state.env.env_name}"
    app              = "${data.terraform_remote_state.app.app_name}"
    service          = "${var.service_name}"
    zerotier_network = "${var.zerotier_network}"
  }
}

data "aws_ami" "ecs" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-2018.03.*-amazon-ecs-optimized"]
  }

  owners = ["amazon"]
}

data "aws_ami" "nat" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat-hvm-*"]
  }

  owners = ["amazon"]
}

locals {
  vendor_ami_id = "${var.amazon_nat ? data.aws_ami.nat.image_id : data.aws_ami.ecs.image_id}"
}

resource "aws_instance" "service" {
  ami           = "${coalesce(element(var.ami_id,count.index),local.vendor_ami_id)}"
  instance_type = "${element(var.instance_type,count.index)}"
  count         = "${var.instance_count}"

  key_name             = "${var.key_name}"
  user_data            = "${data.template_file.user_data_service.rendered}"
  iam_instance_profile = "${local.service_name}"

  vpc_security_group_ids      = ["${concat(list(data.terraform_remote_state.env.sg_env,aws_security_group.service.id),list(data.terraform_remote_state.app.app_sg))}"]
  subnet_id                   = "${element(compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id,formatlist(var.want_subnets ? "%[3]s" : (var.public_network ? "%[1]s" : "%[2]s"),data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets,data.terraform_remote_state.env.fake_subnets))),count.index)}"
  associate_public_ip_address = "${var.public_network ? "true" : "false"}"
  source_dest_check           = "${var.source_dest_check}"

  credit_specification {
    cpu_credits = "unlimited"
  }

  lifecycle {
    ignore_changes = ["*"]
  }

  root_block_device {
    volume_type = "gp2"
    volume_size = "${element(var.root_volume_size,count.index)}"
  }

  ephemeral_block_device {
    device_name  = "/dev/sdb"
    virtual_name = "ephemeral0"
    no_device    = ""
  }

  ephemeral_block_device {
    device_name  = "/dev/sdc"
    virtual_name = "ephemeral1"
    no_device    = ""
  }

  ephemeral_block_device {
    device_name  = "/dev/sdd"
    virtual_name = "ephemeral2"
    no_device    = ""
  }

  ephemeral_block_device {
    device_name  = "/dev/sde"
    virtual_name = "ephemeral3"
    no_device    = ""
  }

  volume_tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

resource "aws_launch_template" "service" {
  name_prefix = "${local.service_name}-${element(var.asg_name,count.index)}-"

  block_device_mappings {
    device_name = "/dev/xvdcz"

    ebs {
      volume_type           = "gp2"
      volume_size           = "${element(var.ecs_volume_size,count.index)}"
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name  = "/dev/sdb"
    virtual_name = "ephemeral0"
  }

  block_device_mappings {
    device_name  = "/dev/sdc"
    virtual_name = "ephemeral1"
  }

  block_device_mappings {
    device_name  = "/dev/sdd"
    virtual_name = "ephemeral2"
  }

  block_device_mappings {
    device_name  = "/dev/sde"
    virtual_name = "ephemeral3"
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  disable_api_termination = false

  ebs_optimized = false

  iam_instance_profile {
    arn = "${aws_iam_instance_profile.service.arn}"
  }

  image_id = "${coalesce(element(var.ami_id,count.index),local.vendor_ami_id)}"

  instance_type = "${element(var.instance_type,count.index)}"
  key_name      = "${var.key_name}"

  monitoring {
    enabled = false
  }

  vpc_security_group_ids = ["${concat(list(data.terraform_remote_state.env.sg_env,aws_security_group.service.id),list(data.terraform_remote_state.app.app_sg))}"]
  user_data              = "${base64encode(data.template_file.user_data_service.rendered)}"

  tag_specifications {
    resource_type = "instance"

    tags {
      "Name"      = "${local.service_name}"
      "Env"       = "${data.terraform_remote_state.env.env_name}"
      "App"       = "${data.terraform_remote_state.app.app_name}"
      "Service"   = "${var.service_name}"
      "ManagedBy" = "terraform"
    }
  }

  count = "${var.asg_count}"
}

locals {
  ses_domain = "${data.terraform_remote_state.app.app_name}-${var.service_name}.${data.terraform_remote_state.env.private_zone_name}"
}

resource "aws_ses_domain_identity" "service" {
  provider = "aws.us_east_1"
  domain   = "${local.ses_domain}"
}

resource "aws_ses_receipt_rule" "s3" {
  provider      = "aws.us_east_1"
  name          = "${local.ses_domain}"
  rule_set_name = "${data.terraform_remote_state.org.domain_name}"
  recipients    = ["${local.ses_domain}"]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"

  s3_action {
    bucket_name       = "${data.terraform_remote_state.env.s3_env_ses}"
    object_key_prefix = "${local.ses_domain}"
    position          = 1
  }
}

resource "aws_ses_domain_dkim" "service" {
  provider = "aws.us_east_1"
  domain   = "${aws_ses_domain_identity.service.domain}"
}

resource "aws_route53_record" "verify_dkim" {
  zone_id = "${data.terraform_remote_state.org.public_zone_id}"
  name    = "${element(aws_ses_domain_dkim.service.dkim_tokens, count.index)}._domainkey.${local.ses_domain}"
  type    = "CNAME"
  ttl     = "600"
  records = ["${element(aws_ses_domain_dkim.service.dkim_tokens, count.index)}.dkim.amazonses.com"]
  count   = 3
}

resource "aws_route53_record" "verify_ses" {
  zone_id = "${data.terraform_remote_state.org.public_zone_id}"
  name    = "_amazonses.${local.ses_domain}"
  type    = "TXT"
  ttl     = "60"
  records = ["${aws_ses_domain_identity.service.verification_token}"]
}

resource "aws_route53_record" "mx" {
  zone_id = "${data.terraform_remote_state.org.public_zone_id}"
  name    = "${local.ses_domain}"
  type    = "MX"
  ttl     = "60"
  records = ["10 inbound-smtp.us-east-1.amazonaws.com"]
}

resource "aws_sns_topic" "service" {
  name  = "${local.service_name}-${element(var.asg_name,count.index)}"
  count = "${var.asg_count}"
}

resource "aws_sqs_queue" "service" {
  name                        = "${local.service_name}-${element(var.asg_name,count.index)}${var.want_fifo ? ".fifo" : ""}"
  policy                      = "${element(data.aws_iam_policy_document.service-sns-sqs.*.json,count.index)}"
  count                       = "${var.asg_count}"
  fifo_queue                  = "${var.want_fifo ? true : false}"
  content_based_deduplication = "${var.want_fifo ? true : false}"

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}

data "aws_iam_policy_document" "service-sns-sqs" {
  statement {
    actions = [
      "sqs:SendMessage",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [
      "arn:aws:sqs:${var.region}:${data.terraform_remote_state.org.aws_account_id}:${local.service_name}-${element(var.asg_name,count.index)}.fifo",
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"

      values = [
        "${element(aws_sns_topic.service.*.arn,count.index)}",
      ]
    }
  }

  count = "${var.asg_count}"
}

resource "aws_sns_topic_subscription" "service" {
  topic_arn = "${element(aws_sns_topic.service.*.arn,count.index)}"
  endpoint  = "${element(aws_sqs_queue.service.*.arn,count.index)}"
  protocol  = "sqs"
  count     = "${var.asg_count}"
}

resource "aws_ecs_cluster" "service" {
  name = "${local.service_name}"
}

resource "aws_autoscaling_group" "service" {
  name = "${local.service_name}-${element(var.asg_name,count.index)}"

  launch_template = {
    id      = "${aws_launch_template.service.id}"
    version = "$$Latest"
  }

  vpc_zone_identifier  = ["${compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id,formatlist(var.want_subnets ? "%[3]s" : (var.public_network ? "%[1]s" : "%[2]s"),data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets,data.terraform_remote_state.env.fake_subnets)))}"]
  min_size             = "${element(var.min_size,count.index)}"
  max_size             = "${element(var.max_size,count.index)}"
  termination_policies = ["${var.termination_policies}"]
  target_group_arns    = ["${compact(list(element(concat(aws_lb_target_group.net.*.arn,list("","")),count.index)))}"]
  count                = "${var.asg_count}"

  tag {
    key                 = "Name"
    value               = "${local.service_name}-${element(var.asg_name,count.index)}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Env"
    value               = "${data.terraform_remote_state.env.env_name}"
    propagate_at_launch = true
  }

  tag {
    key                 = "App"
    value               = "${data.terraform_remote_state.app.app_name}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "${var.service_name}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Patch Group"
    value               = "${local.service_name}"
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "autoscaling ${local.service_name}-${element(var.asg_name,count.index)}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Color"
    value               = "${element(var.asg_name,count.index)}"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_notification" "service" {
  topic_arn = "${element(aws_sns_topic.service.*.arn,count.index)}"

  group_names = [
    "${element(aws_autoscaling_group.service.*.name,count.index)}",
  ]

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]

  count = "${var.asg_count}"
}

module "efs" {
  source   = ".module/fogg-tf/fogg-efs"
  efs_name = "${local.service_name}"
  vpc_id   = "${data.terraform_remote_state.env.vpc_id}"
  env_name = "${data.terraform_remote_state.env.env_name}"
  subnets  = ["${compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id,formatlist(var.want_subnets ? "%[3]s" : (var.public_network ? "%[1]s" : "%[2]s"),data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets,data.terraform_remote_state.env.fake_subnets)))}"]
  az_count = "${var.az_count}"
  want_efs = "${var.want_efs}"
}

resource "aws_security_group_rule" "allow_service_mount" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.service.id}"
  security_group_id        = "${module.efs.efs_sg}"
  count                    = "${var.want_efs}"
  description              = "allow service to mount efs"
}

resource "aws_route53_record" "efs" {
  zone_id = "${data.terraform_remote_state.env.private_zone_id}"
  name    = "${data.terraform_remote_state.app.app_name}-${var.service_name}-efs.${data.terraform_remote_state.env.private_zone_name}"
  type    = "CNAME"
  ttl     = "60"
  records = ["${element(module.efs.efs_dns_names,count.index)}"]
  count   = "${var.want_efs}"
}

resource "aws_security_group_rule" "allow_redis" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.service.id}"
  security_group_id        = "${aws_security_group.cache.id}"
  count                    = "${var.want_elasticache}"
  description              = "allow service to access redis"
}

resource "aws_route53_record" "cache" {
  zone_id = "${data.terraform_remote_state.env.private_zone_id}"
  name    = "${data.terraform_remote_state.app.app_name}-${var.service_name}-cache.${data.terraform_remote_state.env.private_zone_name}"
  type    = "CNAME"
  ttl     = "60"
  records = ["${aws_elasticache_replication_group.service.configuration_endpoint_address}"]
  count   = "${var.want_elasticache}"
}

resource "aws_route53_record" "db" {
  zone_id = "${data.terraform_remote_state.env.private_zone_id}"
  name    = "${data.terraform_remote_state.app.app_name}-${var.service_name}-db.${data.terraform_remote_state.env.private_zone_name}"
  type    = "CNAME"
  ttl     = "60"
  records = ["${aws_rds_cluster.service.endpoint}"]
  count   = "${var.want_aurora}"
}

resource "aws_route53_record" "db_ro" {
  zone_id = "${data.terraform_remote_state.env.private_zone_id}"
  name    = "${data.terraform_remote_state.app.app_name}-${var.service_name}-db-ro.${data.terraform_remote_state.env.private_zone_name}"
  type    = "CNAME"
  ttl     = "60"
  records = ["${aws_rds_cluster.service.reader_endpoint}"]
  count   = "${var.want_aurora}"
}

resource "aws_kms_key" "service" {
  description         = "Service ${var.service_name}"
  enable_key_rotation = false

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }

  count = "${var.want_kms}"
}

resource "aws_kms_alias" "service" {
  name          = "alias/${local.service_name}"
  target_key_id = "${element(coalescelist(aws_kms_key.service.*.id,list(data.terraform_remote_state.reg.kms_key_id)),0)}"
}

resource "aws_codecommit_repository" "service" {
  repository_name = "${local.service_name}"
  description     = "Repo for ${local.service_name} service"
}

resource "aws_codecommit_trigger" "service" {
  depends_on      = ["aws_codecommit_repository.service"]
  repository_name = "${local.service_name}"

  trigger {
    name            = "all"
    events          = ["all"]
    destination_arn = "${aws_sns_topic.codecommit.arn}"
  }
}

resource "aws_ecr_repository" "service" {
  name = "${local.service_name}"
}

resource "aws_sns_topic" "codecommit" {
  name = "${local.service_name}-codecommit"
}

resource "aws_db_subnet_group" "service" {
  name       = "${local.service_name}"
  subnet_ids = ["${compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id,formatlist(var.want_subnets ? "%[3]s" : (var.public_network ? "%[1]s" : "%[2]s"),data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets,data.terraform_remote_state.env.fake_subnets)))}"]

  tags {
    "Name"      = "${local.service_name}-db-subnet"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-db"
    "ManagedBy" = "terraform"
  }

  count = "${var.want_aurora}"
}

resource "aws_rds_cluster_parameter_group" "service" {
  name        = "${local.service_name}"
  family      = "aurora5.6"
  description = "${local.service_name}"

  tags {
    "Name"      = "${local.service_name}-db-cluster-parameter"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-db"
    "ManagedBy" = "terraform"
  }

  count = "${var.want_aurora}"
}

resource "aws_db_parameter_group" "service" {
  name_prefix = "${local.service_name}-"
  family      = "aurora5.6"
  description = "${local.service_name}"

  tags {
    "Name"      = "${local.service_name}-db-parameter"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-db"
    "ManagedBy" = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }

  count = "${var.want_aurora}"
}

resource "aws_rds_cluster_instance" "service" {
  identifier              = "${local.service_name}-${count.index}"
  cluster_identifier      = "${aws_rds_cluster.service.id}"
  instance_class          = "db.t2.small"
  db_subnet_group_name    = "${aws_db_subnet_group.service.name}"
  db_parameter_group_name = "${aws_db_parameter_group.service.name}"

  tags {
    "Name"      = "${local.service_name}-db-${count.index}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-db"
    "ManagedBy" = "terraform"
  }

  count = "${var.want_aurora*var.aurora_instances}"
}

resource "aws_rds_cluster" "service" {
  cluster_identifier              = "${local.service_name}"
  database_name                   = "meh"
  master_username                 = "meh"
  master_password                 = "${local.service_name}"
  vpc_security_group_ids          = ["${data.terraform_remote_state.env.sg_env}", "${data.terraform_remote_state.app.app_sg}", "${aws_security_group.db.id}"]
  db_subnet_group_name            = "${aws_db_subnet_group.service.name}"
  db_cluster_parameter_group_name = "${aws_rds_cluster_parameter_group.service.name}"

  count = "${var.want_aurora}"
}

resource "aws_elasticache_replication_group" "service" {
  replication_group_id          = "${local.service_name}"
  replication_group_description = "${local.service_name}"
  engine                        = "redis"
  engine_version                = "3.2.10"
  node_type                     = "cache.t2.micro"
  port                          = 6379
  parameter_group_name          = "default.redis3.2.cluster.on"
  automatic_failover_enabled    = true
  subnet_group_name             = "${aws_elasticache_subnet_group.service.name}"
  security_group_ids            = ["${data.terraform_remote_state.env.sg_env}", "${data.terraform_remote_state.app.app_sg}", "${aws_security_group.cache.id}"]

  automatic_failover_enabled = true

  cluster_mode {
    replicas_per_node_group = 0
    num_node_groups         = 1
  }

  tags {
    "Name"      = "${local.service_name}-cache"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-cache"
    "ManagedBy" = "terraform"
  }

  lifecycle {
    ignore_changes = ["name"]
  }

  count = "${var.want_elasticache}"
}

resource "aws_elasticache_subnet_group" "service" {
  name       = "${local.service_name}"
  subnet_ids = ["${compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id,formatlist(var.want_subnets ? "%[3]s" : (var.public_network ? "%[1]s" : "%[2]s"),data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets,data.terraform_remote_state.env.fake_subnets)))}"]

  count = "${var.want_elasticache}"
}

locals {
  service_name     = "${data.terraform_remote_state.env.env_name}-${data.terraform_remote_state.app.app_name}-${var.service_name}"
  apig_rest_id     = "${data.terraform_remote_state.env.api_gateway}"
  apig_resource_id = "${data.terraform_remote_state.env.api_gateway_resource}"
  apig_domain_name = "${data.terraform_remote_state.env.private_zone_name}"
}

resource "aws_lb" "net" {
  name               = "${local.service_name}-${element(var.asg_name,count.index)}"
  load_balancer_type = "network"
  internal           = "${var.public_lb == 0 ? true : false}"

  subnets = ["${compact(concat(formatlist(var.public_lb ? "%[1]s" : "%[2]s",data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets)))}"]

  tags {
    Name      = "${local.service_name}-${element(var.asg_name,count.index)}"
    Env       = "${data.terraform_remote_state.env.env_name}"
    App       = "${data.terraform_remote_state.app.app_name}"
    Service   = "${var.service_name}"
    ManagedBy = "terraform"
    Color     = "${element(var.asg_name,count.index)}"
  }

  count = "${var.want_nlb*var.asg_count}"
}

resource "aws_api_gateway_vpc_link" "net" {
  name        = "${local.service_name}-${element(var.asg_name,count.index)}"
  target_arns = ["${aws_lb.net.arn}"]
  count       = "${var.want_nlb*var.asg_count}"
}

resource "aws_lb" "app" {
  name               = "${local.service_name}-${element(var.asg_name,count.index)}"
  load_balancer_type = "application"
  internal           = "${var.public_lb == 0 ? true : false}"

  subnets = ["${compact(concat(formatlist(var.public_lb ? "%[1]s" : "%[2]s",data.terraform_remote_state.env.public_subnets,data.terraform_remote_state.env.private_subnets)))}"]

  security_groups = ["${data.terraform_remote_state.env.sg_env}", "${data.terraform_remote_state.app.app_sg}", "${aws_security_group.app.id}"]

  tags {
    Name      = "${local.service_name}-${element(var.asg_name,count.index)}"
    Env       = "${data.terraform_remote_state.env.env_name}"
    App       = "${data.terraform_remote_state.app.app_name}"
    Service   = "${var.service_name}"
    ManagedBy = "terraform"
    Color     = "${element(var.asg_name,count.index)}"
  }

  count = "${var.want_alb*var.asg_count}"
}

resource "aws_security_group" "app" {
  name        = "${local.service_name}-lb"
  description = "Service ${data.terraform_remote_state.app.app_name}-${var.service_name}-lb"
  vpc_id      = "${data.aws_vpc.current.id}"

  tags {
    "Name"      = "${local.service_name}-lb"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}-lb"
    "ManagedBy" = "terraform"
  }
}

resource "aws_lb_listener" "net" {
  load_balancer_arn = "${element(aws_lb.net.*.arn,count.index)}"
  port              = 443
  protocol          = "TCP"

  default_action {
    target_group_arn = "${element(aws_lb_target_group.net.*.arn,count.index)}"
    type             = "forward"
  }

  count = "${var.want_nlb*var.asg_count}"
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = "${element(aws_lb.app.*.arn,count.index)}"
  port              = 443
  protocol          = "HTTPS"

  default_action {
    target_group_arn = "${element(aws_lb_target_group.app.*.arn,count.index)}"
    type             = "forward"
  }

  certificate_arn = "${data.terraform_remote_state.env.env_cert}"

  ssl_policy = "ELBSecurityPolicy-TLS-1-2-2017-01"

  count = "${var.want_alb*var.asg_count}"
}

resource "aws_lb_target_group" "net" {
  name     = "${local.service_name}-${element(var.asg_name,count.index)}"
  port     = 443
  protocol = "TCP"
  vpc_id   = "${data.aws_vpc.current.id}"
  count    = "${var.want_nlb*var.asg_count}"
}

resource "aws_lb_target_group" "app" {
  name     = "${local.service_name}-${element(var.asg_name,count.index)}"
  port     = 443
  protocol = "HTTPS"
  vpc_id   = "${data.aws_vpc.current.id}"
  count    = "${var.want_alb*var.asg_count}"
}

resource "aws_route53_record" "net" {
  zone_id = "${var.public_lb ? data.terraform_remote_state.org.public_zone_id : data.terraform_remote_state.env.private_zone_id}"
  name    = "${var.public_lb ? "${local.service_name}-${element(var.asg_name,count.index)}.${data.terraform_remote_state.org.domain_name}" : "${data.terraform_remote_state.app.app_name}-${var.service_name}-${element(var.asg_name,count.index)}.${data.terraform_remote_state.env.private_zone_name}"}"
  type    = "A"

  alias {
    name                   = "${element(concat(aws_lb.net.*.dns_name),count.index)}"
    zone_id                = "${element(concat(aws_lb.net.*.zone_id),count.index)}"
    evaluate_target_health = false
  }

  count = "${var.asg_count*signum(var.want_nlb)}"
}

resource "aws_route53_record" "app" {
  zone_id = "${var.public_lb ? data.terraform_remote_state.org.public_zone_id : data.terraform_remote_state.env.private_zone_id}"
  name    = "${var.public_lb ? "${local.service_name}-${element(var.asg_name,count.index)}.${data.terraform_remote_state.org.domain_name}" : "${data.terraform_remote_state.app.app_name}-${var.service_name}-${element(var.asg_name,count.index)}.${data.terraform_remote_state.env.private_zone_name}"}"
  type    = "A"

  alias {
    name                   = "${element(concat(aws_lb.app.*.dns_name),count.index)}"
    zone_id                = "${element(concat(aws_lb.app.*.zone_id),count.index)}"
    evaluate_target_health = false
  }

  count = "${var.asg_count*signum(var.want_alb)}"
}

data "aws_iam_policy_document" "aws_iam_role_batch" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch" {
  name  = "${local.service_name}-batch"
  count = "${var.want_batch}"

  assume_role_policy = "${data.aws_iam_policy_document.aws_iam_role_batch.json}"
}

resource "aws_iam_role_policy_attachment" "AWSBatchServiceRole" {
  role       = "${aws_iam_role.batch.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
  count      = "${var.want_batch}"
}

resource "aws_batch_compute_environment" "batch" {
  compute_environment_name = "${local.service_name}"
  service_role             = "${aws_iam_role.batch.arn}"
  type                     = "UNMANAGED"
  depends_on               = ["aws_iam_role_policy_attachment.AWSBatchServiceRole"]
  count                    = "${var.want_batch}"
}

resource "aws_batch_job_queue" "batch" {
  name                 = "${local.service_name}"
  state                = "ENABLED"
  priority             = 1
  compute_environments = ["${aws_batch_compute_environment.batch.arn}"]
  count                = "${var.want_batch}"
}

resource "aws_ssm_parameter" "fogg_svc" {
  name      = "${local.service_name}.fogg_svc"
  type      = "String"
  value     = "${var.service_name}"
  overwrite = true
}

resource "aws_ssm_parameter" "fogg_svc_sg" {
  name      = "${local.service_name}.fogg_svc_sg"
  type      = "String"
  value     = "${aws_security_group.service.id}"
  overwrite = true
}

resource "aws_ssm_parameter" "fogg_svc_subnets" {
  name      = "${local.service_name}.fogg_svc_subnets"
  type      = "String"
  value     = "${join(" ",compact(concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id)))}"
  overwrite = true
}

resource "aws_ssm_parameter" "fogg_svc_ssh_key" {
  name      = "${local.service_name}.fogg_svc_ssh_key"
  type      = "String"
  value     = "${var.key_name}"
  overwrite = true
}

resource "aws_ssm_parameter" "fogg_svc_ami" {
  name      = "${local.service_name}.fogg_svc_ami"
  type      = "String"
  value     = "${coalesce(element(var.ami_id,count.index),local.vendor_ami_id)}"
  overwrite = true
}

resource "aws_ssm_parameter" "fogg_svc_iam_profile" {
  name      = "${local.service_name}.fogg_svc_iam_profile"
  type      = "String"
  value     = "${local.service_name}"
  overwrite = true
}

resource "random_pet" "svc" {
  keepers = {
    instances = "${join(",",sort(aws_instance.service.*.id))}"
  }
}

resource "random_pet" "bridge" {
  keepers = {
    instances = "${join(",",sort(aws_instance.service.*.id))}"
  }
}

resource "aws_service_discovery_service" "svc" {
  name  = "${random_pet.svc.id}"
  count = "${var.want_sd}"

  health_check_custom_config {
    failure_threshold = "4"
  }

  dns_config {
    namespace_id = "${data.terraform_remote_state.env.private_sd_id}"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_service_discovery_service" "bridge" {
  name  = "${random_pet.bridge.id}"
  count = "${var.want_sd}"

  health_check_custom_config {
    failure_threshold = "4"
  }

  dns_config {
    namespace_id = "${data.terraform_remote_state.env.private_sd_id}"

    dns_records {
      ttl  = 10
      type = "SRV"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "sd" {
  count = "${var.want_sd}"

  zone_id = "${data.terraform_remote_state.env.private_zone_id}"
  name    = "${data.terraform_remote_state.app.app_name}-${var.service_name}"
  type    = "A"

  alias {
    name                   = "${aws_service_discovery_service.svc.name}.${data.terraform_remote_state.env.private_sd_zone_name}"
    zone_id                = "${data.terraform_remote_state.env.private_sd_zone_id}"
    evaluate_target_health = false
  }
}

resource "aws_ssm_patch_group" "svc" {
  baseline_id = "${data.terraform_remote_state.reg.patch_baseline}"
  patch_group = "${local.service_name}"
}

resource "aws_cloudwatch_log_group" "svc" {
  name = "${local.service_name}"

  tags {
    "Name"      = "${local.service_name}"
    "Env"       = "${data.terraform_remote_state.env.env_name}"
    "App"       = "${data.terraform_remote_state.app.app_name}"
    "Service"   = "${var.service_name}"
    "ManagedBy" = "terraform"
  }
}
