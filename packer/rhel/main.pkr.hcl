source "amazon-ebs" "rhel" {
  ami_name      = "${var.ami_name}-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region
  source_ami    = var.source_ami == "" ? null : var.source_ami

  dynamic "source_ami_filter" {
    for_each = var.source_ami == "" ? [1] : []
    content {
      filters = {
        name                = "RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3"
        root-device-type    = "ebs"
        virtualization-type = "hvm"
      }
      owners      = ["309956199498"]
      most_recent = true
    }
  }

  ssh_username           = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file == "" ? null : var.ssh_private_key_file

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, var.extra_tags, {
    Name     = "${var.ami_name}-{{timestamp}}"
    OS       = "RHEL 9"
    Customer = var.customer
  })
}

build {
  sources = ["source.amazon-ebs.rhel"]

  provisioner "shell" {
    inline = [
      # RHEL on-demand images include the HA/AppStream subscriptions automatically.
      # Do not run subscription-manager here; the image is already registered.
      "sudo dnf install -y python3 python3-pip"
    ]
  }

  provisioner "ansible" {
    playbook_file = "../../ansible/base/rhel.yml"
    extra_arguments = [
      "--extra-vars", "customer=${var.customer} extra_packages=${join(",", var.extra_packages)} image_type=${var.department}"
    ]
  }

  provisioner "shell" {
    only = ["amazon-ebs.rhel"]
    inline = [
      "sudo dnf clean all",
      "sudo rm -rf /tmp/* /var/log/*.log /var/tmp/*",
      "sudo rm -f /etc/ssh/ssh_host_*"
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      os_type  = "rhel"
      customer = var.customer
    }
  }

}
