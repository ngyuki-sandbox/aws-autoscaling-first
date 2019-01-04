////////////////////////////////////////////////////////////////////////////////
// AWS

provider "aws" {
  region = "ap-northeast-1"
}

////////////////////////////////////////////////////////////////////////////////
// Variable

variable "key_name" {}

////////////////////////////////////////////////////////////////////////////////
// IAM

resource "aws_iam_instance_profile" "instance" {
  name = "hello-asg-instance"
  role = "${aws_iam_role.instance.id}"
}

resource "aws_iam_role" "instance" {
  name = "hello-asg-instance"

  assume_role_policy = <<EOS
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOS
}

resource "aws_iam_role_policy" "instance" {
  name = "hello-asg-instance"
  role = "${aws_iam_role.instance.id}"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:CompleteLifecycleAction",
                "ec2:DescribeInstances"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

////////////////////////////////////////////////////////////////////////////////
// VPC

locals {
  availability_zones = [
    "ap-northeast-1a",
    "ap-northeast-1c",
  ]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = "${data.aws_vpc.default.id}"
}

data "aws_security_group" "default" {
  name = "default"
}

////////////////////////////////////////////////////////////////////////////////
// AutoScaling

data "aws_ami" "app" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  user_data = <<EOS
#!/bin/bash

set -eux

sleep 60

instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
region=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')

groupName=$(aws ec2 describe-instances \
  --region "$region" \
  --instance-ids "$instance_id" \
  --query 'Reservations[].Instances[].Tags[?Key==`aws:autoscaling:groupName`][].Value' \
  --output text)

aws autoscaling complete-lifecycle-action \
  --region "$region" \
  --auto-scaling-group-name "$groupName" \
  --lifecycle-hook-name "hello-asg-app-launching" \
  --lifecycle-action-result "CONTINUE" \
  --instance-id "$instance_id"

echo ok
EOS
}

resource "aws_launch_template" "app" {
  name                   = "hello-asg-app"
  image_id               = "${data.aws_ami.app.id}"
  instance_type          = "t2.nano"
  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${data.aws_security_group.default.id}"]
  user_data              = "${base64encode(local.user_data)}"

  iam_instance_profile {
    name = "${aws_iam_instance_profile.instance.name}"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 8
      volume_type           = "gp2"
      delete_on_termination = true
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name = "hello-asg-app-${aws_launch_template.app.latest_version}"

  launch_template = {
    id      = "${aws_launch_template.app.id}"
    version = "${aws_launch_template.app.latest_version}"
  }

  min_size = 1
  max_size = 1

  vpc_zone_identifier = ["${data.aws_subnet_ids.default.ids}"]

  initial_lifecycle_hook {
    name                 = "hello-asg-app-launching"
    default_result       = "ABANDON"
    heartbeat_timeout    = 300
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
  }

  tag {
    key                 = "Name"
    value               = "hello-asg-app"
    propagate_at_launch = true
  }

  timeouts {
    delete = "15m"
  }

  lifecycle {
    create_before_destroy = true
  }
}
