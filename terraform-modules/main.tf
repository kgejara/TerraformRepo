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

#resource "aws_instance" "tfmexampleec2instance" {
  #ami           = "ami-0915e09cc7ceee3ab"
  #key_name      = "ansible_ssh_key"
  #security_groups = [aws_security_group.ec2_security_group.name]
  #instance_type = "t2.micro"
  #tags = {
   # Name = "tfmexampleec2instance"
  #}
#}

data "aws_vpc" "default" {
  default = true
}

data "aws_security_group" "default" {
  name   = "default"
  vpc_id = data.aws_vpc.default.id
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
      cat ${local.private_key_filename}
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

