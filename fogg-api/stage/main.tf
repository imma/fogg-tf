variable "rest_api_id" {}
variable "stage_name" {}

variable "domain_name" {
  default = ""
}

variable "want_private_api" {
  default = 0
}

variable "deployment_id" {}
variable "signature" {}

resource "aws_api_gateway_stage" "stage" {
  stage_name    = "${var.stage_name}"
  rest_api_id   = "${var.rest_api_id}"
  deployment_id = "${var.deployment_id}"

  variables {
    alias     = "${var.stage_name}"
    signature = "${var.signature}"
  }

  count = "${var.stage_name == "rc" ? 1 : 0}"
}

resource "aws_api_gateway_stage" "live" {
  stage_name    = "${var.stage_name}"
  rest_api_id   = "${var.rest_api_id}"
  deployment_id = "${var.deployment_id}"

  variables {
    alias = "${var.stage_name}"
  }

  lifecycle {
    ignore_changes = ["deployment_id", "variables"]
  }

  count = "${var.stage_name == "live" ? 1 : 0}"
}

resource "aws_api_gateway_method_settings" "stage" {
  depends_on  = ["aws_api_gateway_stage.stage", "aws_api_gateway_stage.live"]
  rest_api_id = "${var.rest_api_id}"
  stage_name  = "${var.stage_name}"
  method_path = "*/*"

  settings {
    metrics_enabled    = true
    logging_level      = "INFO"
    data_trace_enabled = true
  }
}

resource "aws_api_gateway_base_path_mapping" "stage" {
  depends_on  = ["aws_api_gateway_method_settings.stage"]
  api_id      = "${var.rest_api_id}"
  stage_name  = "${var.stage_name}"
  domain_name = "${var.domain_name}"

  count = "${(var.want_private_api - 1)*-1}"
}

output "invoke_url" {
  value = "${replace(element(coalescelist(aws_api_gateway_base_path_mapping.stage.*.domain_name,aws_api_gateway_stage.stage.*.invoke_url,aws_api_gateway_stage.live.*.invoke_url),0),"/^(https:[/][/])?/","https://")}"
}

output "execution_arn" {
  value = "${element(coalescelist(aws_api_gateway_stage.stage.*.execution_arn,aws_api_gateway_stage.live.*.execution_arn),0)}"
}
