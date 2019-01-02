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

  monitoring {
    enabled = true
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
  max_size = 4

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

// スケールアウトのポリシー
resource "aws_autoscaling_policy" "scaleout" {
  autoscaling_group_name = "${aws_autoscaling_group.app.name}"
  policy_type            = "SimpleScaling"
  name                   = "scaleout"
  cooldown               = 60

  // 調整値は追加/削除するインスタンス数
  adjustment_type = "ChangeInCapacity"

  // 調整値
  scaling_adjustment = "1"
}

// スケールインのポリシー
resource "aws_autoscaling_policy" "scalein" {
  autoscaling_group_name = "${aws_autoscaling_group.app.name}"
  policy_type            = "SimpleScaling"
  name                   = "scalein"
  cooldown               = 60

  // 調整値は追加/削除するインスタンス数
  adjustment_type = "ChangeInCapacity"

  // 調整値
  scaling_adjustment = "-1"
}

// スケールアウトのアラーム
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name  = "cpu high"
  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  period      = "60"

  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.app.name}"
  }

  //  40% より大きいが 3 回続いたらアラーム
  comparison_operator = "GreaterThanThreshold"
  threshold           = "40"
  evaluation_periods  = "3"

  // アラームアクションはスケールアウト
  alarm_actions = ["${aws_autoscaling_policy.scaleout.*.arn}"]
}

// スケールインのアラーム
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name  = "cpu low"
  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  period      = "60"

  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.app.name}"
  }

  //  30% より小さいが 5 回続いたらアラーム
  comparison_operator = "LessThanThreshold"
  threshold           = "30"
  evaluation_periods  = "5"

  // アラームアクションはスケールイン
  alarm_actions = ["${aws_autoscaling_policy.scalein.*.arn}"]
}
