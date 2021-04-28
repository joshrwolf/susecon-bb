provider "aws" {
  region = local.aws_region
}

locals {
  cluster_name = "susecon-bigbang"
  aws_region   = "us-gov-west-1"

  os_config = <<EOF
# Tune vm sysctl for elasticsearch
sysctl -w vm.max_map_count=262144

# Preload kernel modules required by istio-init, required for selinux enforcing instances using istio-init
modprobe xt_REDIRECT
modprobe xt_owner
modprobe xt_statistic
# Persist modules after reboots
printf "xt_REDIRECT\nxt_owner\nxt_statistic\n" | sudo tee -a /etc/modules
EOF

  tags = {
    "terraform" = "true",
    "env"       = local.cluster_name,
  }
}

data "aws_ami" "rhel8" {
  most_recent = true
  owners      = ["219670896067"] # owner is specific to aws gov cloud

  filter {
    name   = "name"
    values = ["RHEL-8.3*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Key Pair
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_pem" {
  filename        = "${local.cluster_name}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

#
# Network
#
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "rke2-${local.cluster_name}"
  cidr = "10.88.0.0/16"

  azs             = ["${local.aws_region}a", "${local.aws_region}b", "${local.aws_region}c"]
  public_subnets  = ["10.88.1.0/24", "10.88.2.0/24", "10.88.3.0/24"]
  private_subnets = ["10.88.101.0/24", "10.88.102.0/24", "10.88.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_vpn_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Add in required tags for proper AWS CCM integration
  public_subnet_tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                            = "1"
  }, local.tags)

  private_subnet_tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"                   = "1"
  }, local.tags)

  tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
  }, local.tags)
}

#
# Server
#
module "rke2" {
  source = "git::https://github.com/rancherfederal/rke2-aws-tf.git?ref=v1.1.8"

  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnets      = module.vpc.public_subnets # Note: Public subnets used for demo purposes, this is not recommended in production

  ami                   = data.aws_ami.rhel8.image_id # Note: Multi OS is primarily for example purposes
  ssh_authorized_keys   = [tls_private_key.ssh.public_key_openssh]
  instance_type         = "t3a.medium"
  controlplane_internal = false # Note this defaults to best practice of true, but is explicitly set to public for demo purposes
  servers               = 1

  pre_userdata = local.os_config

  # Enable AWS Cloud Controller Manager
  enable_ccm = true

  rke2_config = <<-EOT
node-label:
  - "name=server"
  - "os=rhel8"
EOT

  tags = local.tags
}

#
# Generic agent pool
#
module "agents" {
  source = "git::https://github.com/rancherfederal/rke2-aws-tf.git//modules/agent-nodepool?ref=v1.1.8"

  name    = "generic"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets # Note: Public subnets used for demo purposes, this is not recommended in production

  # ami                 = data.aws_ami.rhel8.image_id # Note: Multi OS is primarily for example purposes
  ami                 = "ami-0abd83cca858b0704"
  ssh_authorized_keys = [tls_private_key.ssh.public_key_openssh]
  spot                = true
  asg                 = { min : 2, max : 10, desired : 2 }
  instance_type       = "t3a.2xlarge"

  pre_userdata = local.os_config

  # Enable AWS Cloud Controller Manager and Cluster Autoscaler
  enable_ccm        = true
  enable_autoscaler = true

  rke2_config = <<-EOT
node-label:
  - "name=generic"
  - "os=rhel8"
EOT

  cluster_data = module.rke2.cluster_data

  tags = local.tags
}

# For demonstration only, lock down ssh access in production
resource "aws_security_group_rule" "quickstart_ssh" {
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = module.rke2.cluster_data.cluster_sg
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Generic outputs as examples
output "rke2" {
  value = module.rke2
}

# Example method of fetching kubeconfig from state store, requires aws cli and bash locally
resource "null_resource" "kubeconfig" {
  depends_on = [module.rke2]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "aws s3 cp ${module.rke2.kubeconfig_path} rke2.yaml"
  }
}
