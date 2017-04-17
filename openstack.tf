variable "project" { }
variable "keypair" { }
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

# Create head node
resource "openstack_compute_instance_v2" "master" {
    name = "${var.project}"
    image_name = "${var.os_head_node_image_name}"
    flavor_name = "${var.os_head_node_flavor_name}"
    security_groups = "${var.os_security_groups}"
    key_pair = "${var.keypair}"

    network {
        uuid = "${openstack_networking_network_v2.private-network.id}"
        floating_ip = "${openstack_networking_floatingip_v2.fip.address}"
        access_network = true
    }

    connection {
        type = "ssh"
        user = "${var.os_head_node_user}"
    }

}

# Create compute node
resource "openstack_compute_instance_v2" "node" {
    count = "${var.compute_instance_count}"
    name = "${var.project}${count.index+1}"
    image_name = "${var.os_compute_node_image_name}"
    flavor_name = "${var.os_compute_node_flavor_name}"
    security_groups = "${var.os_security_groups}"
    key_pair = "${var.keypair}"

    network {
        uuid = "${openstack_networking_network_v2.private-network.id}"
    }

    connection {
        type = "ssh"
        user = "${var.os_compute_node_user}"
        bastion_host = "${openstack_compute_instance_v2.master.access_ip_v4}"
    }
}

output "ip" {
    value = "${openstack_compute_instance_v2.master.network.0.floating_ip}"
}

data "template_file" "ssh_cfg" {
    template = "${file("${path.module}/templates/ssh.cfg")}"
    vars {
        master_ip = "${openstack_compute_instance_v2.master.network.0.floating_ip}"
        cidr = "${var.cidr}"
        user_h = "${var.os_head_node_user}"
        user_c = "${var.os_compute_node_user}"
    }
}

data "template_file" "ansible_cfg" {
    template = "${file("${path.module}/templates/ansible.cfg")}"
    vars { }
}

data "template_file" "inventory" {
    template = "${file("${path.module}/templates/inventory")}"
    vars {
        head = "${openstack_compute_instance_v2.master.network.0.floating_ip}"
        nodes = "${join("\n",openstack_compute_instance_v2.node.*.network.0.fixed_ip_v4)}"
    }
}

resource "null_resource" "gen-ssh-template" {
    triggers {
        template_rendered = "${data.template_file.ssh_cfg.rendered}"
    }
    provisioner "local-exec" {
        command = "echo '${data.template_file.ssh_cfg.rendered}' > ./ssh.cfg"
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

resource "null_resource" "gen-ansible-cfg" {
    triggers {
        template_rendered = "${data.template_file.ansible_cfg.rendered}"
    }
    provisioner "local-exec" {
        command = "echo '${data.template_file.ansible_cfg.rendered}' > ./inventory"
    }
}
