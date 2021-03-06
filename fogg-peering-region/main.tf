provider "aws" {}

variable "this_vpc_sg" {}
variable "this_vpc_id" {}
variable "this_vpc_region" {}

variable "this_vpc_cidrs" {
  default = []
}

variable "that_vpc_sg" {}
variable "that_vpc_id" {}
variable "that_vpc_region" {}

variable "that_vpc_cidrs" {
  default = []
}

variable "allow_access" {
  default = 1
}

data "aws_caller_identity" "current" {}

locals {
  vpc_ids      = "${sort(list(var.this_vpc_id,var.that_vpc_id))}"
  peering_name = "${local.vpc_ids[0]}_${local.vpc_ids[1]}"
}

resource "aws_vpc_peering_connection" "peering" {
  peer_owner_id = "${data.aws_caller_identity.current.account_id}"
  peer_vpc_id   = "${var.that_vpc_id}"
  vpc_id        = "${var.this_vpc_id}"
  peer_region   = "${var.that_vpc_region}"

  tags {
    Name = "${local.peering_name}"
  }
}

# let peers access
resource "aws_security_group_rule" "ping_everything" {
  type              = "ingress"
  from_port         = 8
  to_port           = 0
  protocol          = "icmp"
  cidr_blocks       = ["${var.that_vpc_cidrs}"]
  security_group_id = "${var.this_vpc_sg}"
  count             = "${var.allow_access}"
  description       = "peer can ping us"
}

resource "aws_security_group_rule" "ssh_into_everything" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["${var.that_vpc_cidrs}"]
  security_group_id = "${var.this_vpc_sg}"
  count             = "${var.allow_access}"
  description       = "peer can ssh to us"
}

output "peering_connection" {
  value = "${aws_vpc_peering_connection.peering.id}"
}
