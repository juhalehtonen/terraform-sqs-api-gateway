# This SQS & API Gateway creation tool requires Terraform 0.12 or higher.
#
# You can use an AWS credentials file to specify your credentials.
# The default location is $HOME/.aws/credentials on Linux and OS X.
# This way the Terraform configuration can be left without any mention
# of AWS access keys & secrets.
#
# Alternatively, you can use environment variables for all configuration.
#
# Below is an example of how to pass all required values as env vars:
#
# $ export AWS_ACCESS_KEY_ID="anaccesskey"
# $ export AWS_SECRET_ACCESS_KEY="asecretkey"
# $ export TF_VAR_app_name=theappname


# In case you want to use remote state, you'll want to configure the
# S3 bucket for state storage here. This matters when working in groups
# of people.
# terraform {
#   backend "s3" {
#     region = "us-east-1"
#     bucket = "BUCKET NAME HERE"
#     key    = "KEY HERE"
#   }
# }

# Variables
variable "app_name" {
  type = string
  default = "demo"
}

variable "region" {
  default = "eu-north-1"
}

provider "aws" {
  region = "${var.region}"
}


locals {
  common_tags = {
    Environment = "Development"
    Application = "${var.app_name}"
  }
}

data "aws_caller_identity" "current" {}

// ******************** WAF SETUP ******************* //
resource "aws_wafregional_rate_based_rule" "foo" {
  name        = "tfWAFRule"
  metric_name = "tfWAFRule"

  rate_key   = "IP"
  rate_limit = 1500
}

resource "aws_wafregional_web_acl" "foo" {
  depends_on = [aws_wafregional_rate_based_rule.foo]
  name        = "spam"
  metric_name = "spam"

  default_action {
    type = "ALLOW"
  }

  rule {
    action {
      type = "BLOCK"
    }

    type = "RATE_BASED"
    priority = 1
    rule_id  = "${aws_wafregional_rate_based_rule.foo.id}"
  }
}

resource "aws_wafregional_web_acl_association" "association" {
  depends_on = [aws_wafregional_web_acl.foo]
  resource_arn = "${aws_api_gateway_stage.myapp_deployment_stage.arn}"
  web_acl_id   = "${aws_wafregional_web_acl.foo.id}"
}

/*
rror: Error Updating WAF Regional ACL: WAFNonexistentItemException: The referenced item does not exist.

  on main.tf line 61, in resource "aws_wafregional_web_acl" "foo":
  61: resource "aws_wafregional_web_acl" "foo" {
*/



// ******************** SQS SETUP ******************** //
resource "aws_sqs_queue" "myapp_sqs_queue" {
  name                        = "${var.app_name}-queue"
  tags                        = "${local.common_tags}"
}



// ******************** API GATEWAY SETUP ******************** //
resource "aws_api_gateway_rest_api" "myapp_apig" {
  name = "${var.app_name}-apig"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "webhook_resource" {
  path_part   = "webhook"
  parent_id   = "${aws_api_gateway_rest_api.myapp_apig.root_resource_id}"
  rest_api_id = "${aws_api_gateway_rest_api.myapp_apig.id}"
}

resource "aws_api_gateway_resource" "webhook_demo_resource" {
  path_part   = "demo"
  parent_id   = "${aws_api_gateway_resource.webhook_resource.id}"
  rest_api_id = "${aws_api_gateway_rest_api.myapp_apig.id}"
}

resource "aws_api_gateway_method" "webhook_demo_post_method" {
  rest_api_id   = "${aws_api_gateway_rest_api.myapp_apig.id}"
  resource_id   = "${aws_api_gateway_resource.webhook_demo_resource.id}"
  http_method   = "POST"
  authorization = "NONE"
}


resource "aws_api_gateway_method_settings" "webhook_demo_post_method_settings" {
  rest_api_id = "${aws_api_gateway_rest_api.myapp_apig.id}"
  stage_name  = "${aws_api_gateway_stage.myapp_deployment_stage.stage_name}"
  method_path = "${aws_api_gateway_resource.webhook_demo_resource.path_part}/${aws_api_gateway_method.webhook_demo_post_method.http_method}"

  # This works with true, but Cloudwatch must be enabled first on an account level
  settings {
    metrics_enabled = false
    logging_level   = "OFF"
    cache_ttl_in_seconds = 3600 # There is a bug in the provider if this is left out or at 0
  }
}

resource "aws_api_gateway_integration" "webhook_demo_post_integration" {
  depends_on = ["aws_api_gateway_method.webhook_demo_post_method"]
  rest_api_id             = "${aws_api_gateway_rest_api.myapp_apig.id}"
  resource_id             = "${aws_api_gateway_resource.webhook_demo_resource.id}"
  http_method             = "${aws_api_gateway_method.webhook_demo_post_method.http_method}"
  integration_http_method = "POST"
  type                    = "AWS"
  credentials             = "${aws_iam_role.apig-sqs-send-msg-role.arn}"
  uri                     = "arn:aws:apigateway:${var.region}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.myapp_sqs_queue.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  # For a FIFO queue, we'd need: Action=SendMessage&MessageGroupId=1&MessageBody=
  request_templates = {
    "application/json" = <<EOF
Action=SendMessage&MessageBody=
{
  "body" : $input.json('$'),
  "rawbody" : "$util.base64Encode($input.body)",
  "headers": {
    #foreach($header in $input.params().header.keySet())
    "$header": "$util.escapeJavaScript($input.params().header.get($header))" #if($foreach.hasNext),#end

    #end
  },
  "method": "$context.httpMethod",
  "params": {
    #foreach($param in $input.params().path.keySet())
    "$param": "$util.escapeJavaScript($input.params().path.get($param))" #if($foreach.hasNext),#end

    #end
  },
  "query": {
    #foreach($queryParam in $input.params().querystring.keySet())
    "$queryParam": "$util.escapeJavaScript($input.params().querystring.get($queryParam))" #if($foreach.hasNext),#end

    #end
  }
}
EOF
  }
  passthrough_behavior    = "WHEN_NO_TEMPLATES"
}


resource "aws_api_gateway_method_response" "webhook_demo_post_method_response_200" {
  rest_api_id = "${aws_api_gateway_rest_api.myapp_apig.id}"
  resource_id = "${aws_api_gateway_resource.webhook_demo_resource.id}"
  http_method = "${aws_api_gateway_method.webhook_demo_post_method.http_method}"
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "webhook_demo_post_integration_response_200" {
  depends_on = [aws_api_gateway_integration.webhook_demo_post_integration]
  rest_api_id = "${aws_api_gateway_rest_api.myapp_apig.id}"
  resource_id = "${aws_api_gateway_resource.webhook_demo_resource.id}"
  http_method = "${aws_api_gateway_method.webhook_demo_post_method.http_method}"
  status_code = "${aws_api_gateway_method_response.webhook_demo_post_method_response_200.status_code}"
}



resource "aws_iam_role" "apig-sqs-send-msg-role" {
  name = "${var.app_name}-apig-sqs-send-msg-role"
  tags = "${local.common_tags}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "apig-sqs-send-msg-policy" {
  name        = "${var.app_name}-apig-sqs-send-msg-policy"
  description = "Policy allowing APIG to write to SQS for ${var.app_name}"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
           "Effect": "Allow",
           "Resource": [
               "*"
           ],
           "Action": [
               "logs:CreateLogGroup",
               "logs:CreateLogStream",
               "logs:PutLogEvents"
           ]
       },
       {
          "Effect": "Allow",
          "Action": "sqs:SendMessage",
          "Resource": "${aws_sqs_queue.myapp_sqs_queue.arn}"
       }
    ]
}
EOF
}

## IAM Role Policies
resource "aws_iam_role_policy_attachment" "terraform_apig_sqs_policy_attach" {
  role       = "${aws_iam_role.apig-sqs-send-msg-role.id}"
  policy_arn = "${aws_iam_policy.apig-sqs-send-msg-policy.arn}"
}


# This works, but one needs to enable logging on an account level / per region first
# resource "aws_cloudwatch_log_group" "webhook_demo_log_group" {
#   name              = "APIG-Execution-Logs_${aws_api_gateway_rest_api.myapp_apig.name}"
#   retention_in_days = 30
# }

## Setup the stages and deploy to the stage when terraform is run.
resource "aws_api_gateway_stage" "myapp_deployment_stage" {
  stage_name    = "dev-temp" // This a hack to fix the API being auto deployed.
  rest_api_id   = "${aws_api_gateway_rest_api.myapp_apig.id}"
  deployment_id = "${aws_api_gateway_deployment.myapp_deployment.id}"
}

resource "aws_api_gateway_deployment" "myapp_deployment" {
  depends_on = [aws_api_gateway_integration.webhook_demo_post_integration]
  rest_api_id     = "${aws_api_gateway_rest_api.myapp_apig.id}"
  stage_name      = "dev"
}

# Output our important values

output "base_url" {
  value = "${aws_api_gateway_deployment.myapp_deployment.invoke_url}"
}

output "post_url" {
  value = "${aws_api_gateway_resource.webhook_demo_resource.path}"
}

output "sqs_url" {
  value = "${aws_sqs_queue.myapp_sqs_queue.id}"
}
