variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "ami_name" {
  type    = string
  default = "golden-debian-13-base"
}

variable "customer" {
  type    = string
  default = "shared"
}

variable "department" {
  type    = string
  default = "base"
}

variable "extra_packages" {
  type    = list(string)
  default = []
}

variable "source_ami" {
  type    = string
  default = ""
}

variable "ssh_keypair_name" {
  type    = string
  default = ""
}

variable "ssh_username" {
  type    = string
  default = "admin"
}

variable "ssh_private_key_file" {
  type    = string
  default = ""
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "GoldenImage"
    ManagedBy = "Packer"
    Source    = "golden-image-pipeline"
  }
}