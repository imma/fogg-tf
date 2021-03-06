resource "aws_cognito_user_group" "org" {
  name         = "${var.account_name}"
  user_pool_id = "${aws_cognito_user_pool.org.id}"
  description  = "Managed by Terraform"
  precedence   = 42
  role_arn     = "${aws_iam_role.org_idp_group.arn}"
}

resource "aws_cognito_user_pool_client" "org" {
  name         = "${var.account_name}"
  user_pool_id = "${aws_cognito_user_pool.org.id}"

  write_attributes = ["email", "phone_number"]

  supported_identity_providers = ["COGNITO"]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_scopes                 = ["openid", "phone", "aws.cognito.signin.user.admin", "profile", "email"]

  callback_urls = ["https://${var.domain_name}/callback"]
  logout_urls   = ["https://${var.domain_name}/logout"]
}

resource "aws_cognito_identity_pool" "org" {
  identity_pool_name               = "${var.account_name}"
  allow_unauthenticated_identities = true

  cognito_identity_providers {
    client_id               = "${aws_cognito_user_pool_client.org.id}"
    provider_name           = "${aws_cognito_user_pool.org.endpoint}"
    server_side_token_check = false
  }
}

resource "aws_cognito_identity_pool_roles_attachment" "org_authenticated" {
  identity_pool_id = "${aws_cognito_identity_pool.org.id}"

  roles {
    "authenticated"   = "${aws_iam_role.org_idp_authenticated.arn}"
    "unauthenticated" = "${aws_iam_role.org_idp_unauthenticated.arn}"
  }
}

resource "aws_cognito_user_pool" "org" {
  name = "${var.account_name}"

  email_verification_subject = "Device Verification Code"
  email_verification_message = "{####}"
  sms_verification_message   = "{####}"
  alias_attributes           = ["email", "preferred_username"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  device_configuration {
    challenge_required_on_new_device = true
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  email_configuration {
    reply_to_email_address = "iam@defn.sh"
  }

  password_policy {
    minimum_length    = 10
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  schema {
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    name                     = "email"
    required                 = true

    string_attribute_constraints {
      min_length = 7
      max_length = 80
    }
  }

  schema {
    attribute_data_type      = "Number"
    developer_only_attribute = false
    mutable                  = true
    name                     = "ssn"
    required                 = false

    number_attribute_constraints {
      min_value = 0
      max_value = 1000
    }
  }

  schema {
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    name                     = "dumbass"
    required                 = false

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  mfa_configuration = "ON"

  sms_configuration {
    external_id    = "12345"
    sns_caller_arn = "${aws_iam_role.org_idp_sns.arn}"
  }

  tags {}
}

resource "aws_iam_role" "org_idp_sns" {
  name = "${var.account_name}-idp-sns"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "cognito-idp.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "12345"
        }
      }
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "org_idp_sns" {
  name = "${var.account_name}-idp-sns"
  role = "${aws_iam_role.org_idp_sns.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sns:publish"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role" "org_idp_group" {
  name = "${var.account_name}-idp-group"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_user_pool.org.arn}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
EOF
}

resource "aws_iam_role" "org_idp_authenticated" {
  name = "${var.account_name}-idp-authenticated"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_identity_pool.org.id}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "org_idp_authenticated" {
  name = "${var.account_name}-idp-authenticated"
  role = "${aws_iam_role.org_idp_authenticated.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role" "org_idp_unauthenticated" {
  name = "${var.account_name}-idp-unauthenticated"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_identity_pool.org.id}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "unauthenticated"
        }
      }
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "org_idp_unauthenticated" {
  name = "${var.account_name}-idp-unauthenticated"
  role = "${aws_iam_role.org_idp_unauthenticated.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}
