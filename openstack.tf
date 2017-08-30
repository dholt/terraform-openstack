variable "project" { }
variable "key" { }
variable "os_tenant_name" { }
variable "os_auth_url" { }
variable "os_domain_name" { }
variable "os_external_gateway" { }
variable "os_floating_ip_pool" { }
variable "cidr" { }
variable "dns_nameservers" { type = "list" }
variable "os_head_node_image_name" { }
variable "os_compute_node_image_name" { }
variable "os_head_node_flavor_name" { }
variable "os_head_node_user" { }
variable "os_compute_node_user" { }
variable "os_compute_node_flavor_name" { }
variable "os_security_groups" { type = "list" }
variable "compute_instance_count" { }

# Configure OpenStack provider
provider "openstack" {
    tenant_name = "${var.os_tenant_name}"
    auth_url = "${var.os_auth_url}"
    domain_name = "${var.os_domain_name}"
}

# Create private network
resource "openstack_networking_network_v2" "private-network" {
    name = "${var.project}-network"
    admin_state_up = "true"
}

# Create private subnet
resource "openstack_networking_subnet_v2" "private-subnet" {
  name = "${var.project}-subnet"
  network_id = "${openstack_networking_network_v2.private-network.id}"
  cidr       = "${var.cidr}"
  dns_nameservers = "${var.dns_nameservers}"
  ip_version = 4
}

# Create router for private subnet
resource "openstack_networking_router_v2" "private-router" {
  name = "${var.project}-router"
  external_gateway = "${var.os_external_gateway}"
  admin_state_up = "true"
}

# Create router interface for private subnet
resource "openstack_networking_router_interface_v2" "router-interface" {
  router_id = "${openstack_networking_router_v2.private-router.id}"
  subnet_id = "${openstack_networking_subnet_v2.private-subnet.id}"
}

# Create floating IP for head node
resource "openstack_networking_floatingip_v2" "fip" {
    pool = "${var.os_floating_ip_pool}"
}

# Associate floating IP with head node
resource "openstack_compute_floatingip_associate_v2" "fip" {
    floating_ip = "${openstack_networking_floatingip_v2.fip.address}"
    instance_id = "${openstack_compute_instance_v2.master.id}"
}

# Create Keypair
resource "openstack_compute_keypair_v2" "keypair" {
    name = "${var.project}-keypair"
    public_key = "${file("${var.key}.pub")}"
}

# Create head node
resource "openstack_compute_instance_v2" "master" {
    name = "${var.project}"
    image_name = "${var.os_head_node_image_name}"
    flavor_name = "${var.os_head_node_flavor_name}"
    security_groups = "${var.os_security_groups}"
    key_pair = "${openstack_compute_keypair_v2.keypair.name}"

    network {
        uuid = "${openstack_networking_network_v2.private-network.id}"
        access_network = true
    }
}

# Provision head node
resource "null_resource" "provision_master" {
    depends_on = ["openstack_compute_floatingip_associate_v2.fip"]
    connection {
        type = "ssh"
        user = "${var.os_head_node_user}"
        host = "${openstack_networking_floatingip_v2.fip.address}"
        private_key = "${file("${var.key}")}"
    }

    provisioner "file" {
        source = "${var.key}"
        destination = "~/.ssh/id_rsa"
    }

    provisioner "remote-exec" {
        inline = [
            "chmod 0600 ~/.ssh/id_rsa",
        ]
    }
}

# Create compute node
resource "openstack_compute_instance_v2" "node" {
    count = "${var.compute_instance_count}"
    name = "${var.project}${count.index+1}"
    image_name = "${var.os_compute_node_image_name}"
    flavor_name = "${var.os_compute_node_flavor_name}"
    security_groups = "${var.os_security_groups}"
    key_pair = "${openstack_compute_keypair_v2.keypair.name}"

    network {
        uuid = "${openstack_networking_network_v2.private-network.id}"
    }

    connection {
        type = "ssh"
        user = "${var.os_compute_node_user}"
        private_key = "${file("${var.key}")}"
        bastion_host = "${openstack_compute_instance_v2.master.access_ip_v4}"
    }
}

output "ip" {
    value = "${openstack_networking_floatingip_v2.fip.address}"
}

data "template_file" "ssh_cfg" {
    template = "${file("${path.module}/templates/ssh.cfg")}"
    vars {
        master_ip = "${openstack_networking_floatingip_v2.fip.address}"
        cidr = "${var.cidr}"
        user_h = "${var.os_head_node_user}"
        user_c = "${var.os_compute_node_user}"
        ssh_key = "${var.key}"
    }
}

data "template_file" "ansible_cfg" {
    template = "${file("${path.module}/templates/ansible.cfg")}"
    vars { }
}

data "template_file" "inventory" {
    template = "${file("${path.module}/templates/inventory")}"
    vars {
        head = "${openstack_networking_floatingip_v2.fip.address}"
        nodes = "${join("\n",openstack_compute_instance_v2.node.*.network.0.fixed_ip_v4)}"
    }
}

resource "null_resource" "gen-ssh-cfg" {
    triggers {
        template_rendered = "${data.template_file.ssh_cfg.rendered}"
    }
    provisioner "local-exec" {
        command = "echo '${data.template_file.ssh_cfg.rendered}' > ./ssh.cfg"
    }
}

resource "null_resource" "gen-ansible-cfg" {
    triggers {
        template_rendered = "${data.template_file.ansible_cfg.rendered}"
    }
    provisioner "local-exec" {
        command = "echo '${data.template_file.ansible_cfg.rendered}' > ./ansible.cfg"
    }
}

resource "null_resource" "gen-ansible-inventory" {
    triggers {
        template_rendered = "${data.template_file.inventory.rendered}"
    }
    provisioner "local-exec" {
        command = "echo '${data.template_file.inventory.rendered}' > ./inventory"
    }
}

