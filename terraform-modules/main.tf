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

resource "aws_s3_bucket" "remote_state" {
  bucket = var.bucket_name
  acl    = "private"

  versioning {
    enabled = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE DYNAMODB TABLE
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_locks" {
  name           = var.dynamodb_lock_table_name
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

resource "aws_instance" "tfmexampleec2instance" {
  ami           = "ami-0915e09cc7ceee3ab"
  key_name      = "ansible_ssh_key"
  security_groups = [aws_security_group.ec2_security_group.name]
  instance_type = "t2.micro"
  tags = {
    Name = "tfmexampleec2instance"
  }
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
      chmod 600 ${local.private_key_filename}
      ansible-playbook -vvv -u ec2-user -i ../../AnsibleRepo/ansible-playbooks/aws_ec2.yaml  --private-key ${local.private_key_filename} ../../AnsibleRepo/ansible-playbooks/playbook.yaml
    EOT
  }
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

resource "aws_security_group" "ec2_security_group" {
  name   = "ansible_ec2_ssh_access"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
