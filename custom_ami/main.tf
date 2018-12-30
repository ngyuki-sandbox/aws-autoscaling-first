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
  owners      = ["self"]
  name_regex  = "^hello-asg-\\d{8}T\\d{6}$"
  most_recent = true
}

locals {
  user_data = <<EOS
#!/bin/bash
systemctl start  nginx.service
systemctl enable nginx.service
systemctl status nginx.service

echo v1 | sudo tee /usr/share/nginx/html/index.html
EOS
}

resource "aws_launch_configuration" "app" {
  name_prefix     = "hello-asg-app-"
  image_id        = "${data.aws_ami.app.id}"
  instance_type   = "t2.nano"
  key_name        = "${var.key_name}"
  security_groups = ["${data.aws_security_group.default.id}"]
  user_data       = "${local.user_data}"

  root_block_device {
    volume_size           = 8
    volume_type           = "gp2"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "app" {
  name                   = "hello-asg-app"
  image_id               = "${data.aws_ami.app.id}"
  instance_type          = "t2.nano"
  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${data.aws_security_group.default.id}"]
  user_data              = "${base64encode(local.user_data)}"

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
  /*
  name                 = "${aws_launch_configuration.app.name}"
  launch_configuration = "${aws_launch_configuration.app.name}"
  */

  name = "hello-asg-app-${aws_launch_template.app.latest_version}"

  launch_template = {
    id      = "${aws_launch_template.app.id}"
    version = "${aws_launch_template.app.latest_version}"
  }

  min_size = 2
  max_size = 4

  vpc_zone_identifier = ["${data.aws_subnet_ids.default.ids}"]

  health_check_type = "ELB"
  target_group_arns = ["${aws_lb_target_group.app.arn}"]

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

////////////////////////////////////////////////////////////////////////////////
// ELB

resource "aws_lb" "app" {
  name               = "hello-asg-app"
  load_balancer_type = "application"
  ip_address_type    = "ipv4"
  security_groups    = ["${data.aws_security_group.default.id}"]
  subnets            = ["${data.aws_subnet_ids.default.ids}"]
}

resource "aws_lb_target_group" "app" {
  name     = "hello-asg-app"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${data.aws_vpc.default.id}"

  health_check {
    protocol            = "HTTP"
    path                = "/"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 10
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = "${aws_lb.app.arn}"
  protocol          = "HTTP"
  port              = "80"

  default_action {
    target_group_arn = "${aws_lb_target_group.app.arn}"
    type             = "forward"
  }
}
