variable "api_name" {}
variable "rest_api_id" {}
variable "resource_id" {}
variable "invoke_arn" {}

variable "http_method" {
  default = "ANY"
}

resource "aws_api_gateway_resource" "fn" {
  rest_api_id = "${var.rest_api_id}"
  parent_id   = "${var.resource_id}"
  path_part   = "${var.api_name}"
}

resource "aws_api_gateway_method" "fn" {
  rest_api_id   = "${var.rest_api_id}"
  resource_id   = "${aws_api_gateway_resource.fn.id}"
  http_method   = "${var.http_method}"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "fn" {
  rest_api_id             = "${var.rest_api_id}"
  resource_id             = "${aws_api_gateway_resource.fn.id}"
  uri                     = "${replace(var.invoke_arn,"/invocations",":$${stageVariables.alias}/invocations")}"
  http_method             = "${aws_api_gateway_method.fn.http_method}"
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  content_handling        = "CONVERT_TO_TEXT"
}

output "resource" {
  value = "${aws_api_gateway_resource.fn.id}"
}

output "method" {
  value = "${aws_api_gateway_method.fn.id}"
}

output "integration" {
  value = "${aws_api_gateway_integration.fn.id}"
}

output "signature" {
  value = "${var.resource_id}-${aws_api_gateway_method.fn.id}-${aws_api_gateway_integration.fn.id}-${var.rest_api_id}-${var.resource_id}-${var.invoke_arn}-${var.http_method}-${var.rest_api_id}"
}
