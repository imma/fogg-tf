variable "org" {
  default = []
}

variable "service" {
  default = {}
}

variable "ipv6_service" {
  default = {}
}

variable "region" {}

variable "az_count" {}

variable "service_name" {}

variable "display_name" {
  default = ""
}

variable "public_network" {
  default = "0"
}

variable "public_port" {
  default = "0"
}

variable "want_elasticache" {
  default = "0"
}

variable "want_aurora" {
  default = "0"
}

variable "want_fargate" {
  default = "0"
}

variable "fargate_image" {
  default = "imma/ubuntu:shell"
}

variable "aurora_instances" {
  default = "1"
}

variable "public_lb" {
  default = "0"
}

variable "want_nlb" {
  default = "0"
}

variable "want_alb" {
  default = "0"
}

variable "want_efs" {
  default = "0"
}

variable "want_vpn" {
  default = "1"
}

variable "want_vgw" {
  default = "0"
}

variable "want_nat" {
  default = "0"
}

variable "want_nat_instance" {
  default = "1"
}

variable "want_nat_interface" {
  default = "1"
}

variable "want_ipv6" {
  default = "0"
}

variable "want_routes" {
  default = "0"
}

variable "want_subnets" {
  default = "1"
}

variable "want_fifo" {
  default = "1"
}

variable "want_kms" {
  default = "0"
}

variable "want_ecs_svc" {
  default = "1"
}

variable "want_sd" {
  default = "1"
}

variable "want_batch" {
  default = "0"
}

variable "zerotier_network" {
  default = ""
}

variable "source_dest_check" {
  default = true
}

variable "user_data" {
  default = ".module/fogg-tf/init/user-data-ecs.template"
}

variable "ecs_image" {
  default = "imma/ubuntu:base"
}

variable "ipv6_service_bits" {
  default = 8
}

variable "service_bits" {}

variable "instance_count" {
  default = 0
}

variable "asg_count" {
  default = 1
}

variable "asg_name" {
  default = ["live", "rc"]
}

variable "instance_type" {
  default = ["t3.nano"]
}

variable "instance_spot_type" {
  default = ["t3.micro"]
}

variable "instance_max_price" {
  default = ["0.004"]
}

variable "ami_id" {
  default = [""]
}

variable "root_volume_size" {
  default = ["8"]
}

variable "ecs_volume_size" {
  default = ["22"]
}

variable "min_size" {
  default = ["0"]
}

variable "max_size" {
  default = ["12"]
}

variable "termination_policies" {
  default = ["OldestInstance"]
}

variable "block" {
  default = "block-ubuntu"
}

variable "key_name" {
  default = "default"
}

variable "amazon_linux" {
  default = false
}

variable "amazon_nat" {
  default = false
}

output "asg_names" {
  value = ["${aws_autoscaling_group.service.*.name}"]
}

output "service_name" {
  value = "${var.service_name}"
}

output "env_sg" {
  value = "${data.terraform_remote_state.env.sg_env}"
}

output "app_sg" {
  value = "${data.terraform_remote_state.app.app_sg}"
}

output "service_sg" {
  value = "${aws_security_group.service.id}"
}

output "service_subnets" {
  value = ["${concat(aws_subnet.service.*.id,aws_subnet.service_v6.*.id)}"]
}

output "key_name" {
  value = "${var.key_name}"
}

output "service_sqs" {
  value = ["${aws_sqs_queue.service.*.id}"]
}

output "service_iam_role" {
  value = "${aws_iam_role.service.name}"
}

output "service_iam_profile" {
  value = "${aws_iam_instance_profile.service.name}"
}

output "service_ami" {
  value = "${element(aws_launch_template.service.*.image_id,0)}"
}

output "block" {
  value = "${var.block}"
}

output "route_tables" {
  value = ["${aws_route_table.service.*.id}"]
}

output "region" {
  value = "${var.region}"
}

output "role" {
  value = "${aws_iam_role.service.arn}"
}

output "private_ips" {
  value = ["${aws_instance.service.*.private_ip}"]
}

output "public_ips" {
  value = ["${aws_instance.service.*.public_ip}"]
}

output "public_ips_v6" {
  value = ["${zipmap(aws_instance.service.*.id,aws_instance.service.*.ipv6_addresses)}"]
}

output "instance_ids" {
  value = ["${aws_instance.service.*.id}"]
}

output "instance_azs" {
  value = ["${aws_instance.service.*.availability_zone}"]
}

output "kms_arn" {
  value = "${element(coalescelist(aws_kms_key.service.*.arn,list(data.terraform_remote_state.env.kms_arn)),0)}"
}

output "kms_key_id" {
  value = "${element(coalescelist(aws_kms_key.service.*.key_id,list(data.terraform_remote_state.env.kms_key_id)),0)}"
}

output "ecs_id" {
  value = "${aws_ecs_cluster.service.id}"
}

output "ecs_service_name" {
  value = "${local.service_name}"
}
