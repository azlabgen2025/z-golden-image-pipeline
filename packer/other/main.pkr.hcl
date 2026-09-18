source "amazon-ebs" "other" {
  ami_name      = "${var.ami_name}-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region
  source_ami    = var.source_ami == "" ? null : var.source_ami

  dynamic "source_ami_filter" {
    for_each = var.source_ami == "" ? [1] : []
    content {
      filters = {
        name                = "al2023-ami-2023.*-x86_64"
        root-device-type    = "ebs"
        virtualization-type = "hvm"
      }
      owners      = ["amazon"]
      most_recent = true
    }
  }

  ssh_username = var.ssh_username

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, var.extra_tags, {
    Name     = "${var.ami_name}-{{timestamp}}"
    OS       = "Other / Custom"
    Customer = var.customer
  })
}

build {
  sources = ["source.amazon-ebs.other"]

  provisioner "shell" {
    inline = [
      "(command -v apt-get >/dev/null && (command -v python3 >/dev/null || sudo apt-get update -y && sudo apt-get install -y python3)) || (command -v dnf >/dev/null && (command -v python3 >/dev/null || sudo dnf install -y python3)) || (command -v yum >/dev/null && (command -v python3 >/dev/null || sudo yum install -y python3)) || (command -v apk >/dev/null && (command -v python3 >/dev/null || sudo apk add --no-cache python3))",
      "command -v python3 >/dev/null || { echo 'python3 not available'; exit 1; }"
    ]
  }

  provisioner "ansible" {
    playbook_file = "../../ansible/base/other.yml"
    extra_arguments = [
      "--extra-vars", "customer=${var.customer} extra_packages=${join(",", var.extra_packages)} image_type=${var.department}"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo rm -rf /tmp/* /var/tmp/*",
      "sudo rm -f /var/log/*.log"
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      os_type  = "other"
      customer = var.customer
    }
  }

}
