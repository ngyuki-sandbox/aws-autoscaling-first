////////////////////////////////////////////////////////////////////////////////
// AWS

provider "aws" {
  region = "ap-northeast-1"
}

////////////////////////////////////////////////////////////////////////////////
// Variable

variable "key_name" {}

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

resource "aws_launch_template" "app" {
  name                   = "hello-asg-app"
  image_id               = "${data.aws_ami.app.id}"
  instance_type          = "t2.nano"
  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${data.aws_security_group.default.id}"]

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

resource "aws_autoscaling_schedule" "single" {
  scheduled_action_name  = "single"
  autoscaling_group_name = "${aws_autoscaling_group.app.name}"
  recurrence             = "5-59/10 * * * *"

  desired_capacity = 1
  min_size         = 1
  max_size         = 1
}

resource "aws_autoscaling_schedule" "multi" {
  scheduled_action_name  = "multi"
  autoscaling_group_name = "${aws_autoscaling_group.app.name}"
  recurrence             = "0-59/10 * * * *"

  desired_capacity = 2
  min_size         = 2
  max_size         = 2
}
