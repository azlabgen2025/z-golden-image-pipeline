source "amazon-ebs" "almalinux" {
  ami_name      = "${var.ami_name}-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region
  source_ami    = var.source_ami == "" ? null : var.source_ami

  dynamic "source_ami_filter" {
    for_each = var.source_ami == "" ? [1] : []
    content {
      filters = {
        name                = "AlmaLinux OS 9.* x86_64*"
        root-device-type    = "ebs"
        virtualization-type = "hvm"
      }
      owners      = ["679593333241"]
      most_recent = true
    }
  }

  ssh_username           = var.ssh_username
  ssh_keypair_name     = var.ssh_keypair_name == "" ? null : var.ssh_keypair_name
  ssh_private_key_file = var.ssh_private_key_file == "" ? null : var.ssh_private_key_file

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, var.extra_tags, {
    Name     = "${var.ami_name}-{{timestamp}}"
    OS       = "AlmaLinux 9"
    Customer = var.customer
  })
}

build {
  sources = ["source.amazon-ebs.almalinux"]

  provisioner "shell" {
    inline = [
      "sudo dnf install -y python3 python3-pip"
    ]
  }

  provisioner "ansible" {
    playbook_file = "../../ansible/base/almalinux.yml"
    extra_arguments = [
      "--extra-vars", "customer=${var.customer} extra_packages=${join(",", var.extra_packages)} image_type=${var.department}"
    ]
  }

  provisioner "shell" {
    only = ["amazon-ebs.almalinux"]
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
      os_type  = "almalinux"
      customer = var.customer
    }
  }

}
