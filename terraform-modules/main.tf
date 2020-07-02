# Require TF version to most recent
terraform {
  required_version = "=0.12.24"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A VERSIONED S3 BUCKET AS A TERRAFORM BACKEND AND A DYNAMODB TABLE FOR LOCKING
# ---------------------------------------------------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------------------------------------------------
# CONFIGURE S3 AS A BACKEND
# Note that this has been commented out because of a slightly awkward chicken and egg: you must first apply this
# module without a backend to create the S3 bucket and DynamoDB table and only then can you uncomment the section
# below and run terraform init to use this module with a backend.
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  backend "s3" {
  region         = "us-east-1"
  bucket         = "terraformsremotestate123"
  key            = "terraform.tfstate"
  encrypt        = true
    dynamodb_table = "terraform-locks-example"
 }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE S3 BUCKET
# ---------------------------------------------------------------------------------------------------------------------
module "aws_s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = var.bucket_name
  acl    = "private"

  versioning = {
    enabled = true
  }

}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE DYNAMODB TABLE
# ---------------------------------------------------------------------------------------------------------------------
module "aws_dynamodb_table" {
  source   = "terraform-aws-modules/dynamodb-table/aws"
  name     = var.dynamodb_lock_table_name
  read_capacity  = 1
  write_capacity = 1
  hash_key = "LockID"

  attributes = [
    {
      name = "LockID"
      type = "S"
    }
  ]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "all" {
  vpc_id = data.aws_vpc.default.id
}

module "security_group" {
  source = "terraform-aws-modules/security-group/aws"
  name        = "nginx-web-server_sg"
  description = "Security group for nginx with custom ports open within VPC, and PostgreSQL publicly open"
  vpc_id = data.aws_vpc.default.id
  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "nginx-web-server 80 ingress port"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "22 ssh ingress port"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "nginx-web-server egress allow all ports"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
}

module "ec2_with_t2_unlimited" {
  source = "terraform-aws-modules/ec2-instance/aws"
  instance_count = 1
  name          = "tfmexampleec2instance"
  ami           = "ami-0915e09cc7ceee3ab"
  instance_type = "t2.micro"
  key_name      = "ansible_ssh_key"
  cpu_credits   = "unlimited"
  subnet_id     = tolist(data.aws_subnet_ids.all.ids)[0]
  vpc_security_group_ids      = [module.security_group.this_security_group_id]
  associate_public_ip_address = true
}

resource "null_resource" "ansible-execution" {
  triggers = {
    always_run = "${timestamp()}"
  }
  provisioner "local-exec" {
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "false"
    }
    command = <<EOT
      pip install boto3 botocore
      chmod 600 ${local.private_key_filename}
      ansible-playbook -vvv -u ec2-user -i ../../AnsibleRepo/ansible-playbooks/aws_ec2.yaml  --private-key ${local.private_key_filename} ../../AnsibleRepo/ansible-playbooks/playbook.yaml
    EOT
  }
depends_on = [module.ec2_with_t2_unlimited]
}

locals {
  public_key_filename  = "${path.cwd}/id_rsa.pub"
  private_key_filename = "${path.cwd}/id_rsa.pem"
}

resource "tls_private_key" "generated" {
  algorithm = "RSA"
}

resource "local_file" "public_key_pub" {
  content  = tls_private_key.generated.public_key_openssh
  filename = local.public_key_filename
}

resource "local_file" "private_key_pem" {
  content  = tls_private_key.generated.private_key_pem
  filename = local.private_key_filename
}

resource "aws_key_pair" "dev_ssh_key" {
  key_name   = "ansible_ssh_key"
  public_key = local_file.public_key_pub.content
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE API GATEWAY
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_api_gateway_rest_api" "api" {
  name = "myapi"
}

resource "aws_api_gateway_deployment" "prod" {
  depends_on  = ["aws_api_gateway_integration.integration"]
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  stage_name  = "prod"
}


resource "aws_api_gateway_resource" "resource" {
  path_part   = "resource"
  parent_id   = "${aws_api_gateway_rest_api.api.root_resource_id}"
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
}

resource "aws_api_gateway_method" "method" {
  rest_api_id   = "${aws_api_gateway_rest_api.api.id}"
  resource_id   = "${aws_api_gateway_resource.resource.id}"
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = "${aws_api_gateway_rest_api.api.id}"
  resource_id             = "${aws_api_gateway_resource.resource.id}"
  http_method             = "${aws_api_gateway_method.method.http_method}"
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "${aws_lambda_function.lambda.invoke_arn}"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE API LAMDA FUNTION
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_lambda_function" "lambda" {
  filename      = "function.zip"
  function_name = "lambda_placeholder_function"
  role          = "${aws_iam_role.iam_for_lambda.arn}"
  handler       = "lambda_function.my_handler"
  runtime = "python3.8"
  source_code_hash = "${filebase64sha256("function.zip")}"
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.lambda.function_name}"
  principal     = "apigateway.amazonaws.com"

  # More: http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-using-iam-policies-to-invoke-api.html
  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*/*"

}

resource "aws_iam_role" "iam_for_lambda" {
  name = "iam_for_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}
