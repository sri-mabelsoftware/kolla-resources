#!/bin/bash
set -e

MGMT_IP=192.168.1.44
MGMT_NETMASK=255.255.255.0
MGMT_GATEWAY=192.168.1.1
MGMT_DNS="8.8.8.8 8.8.4.4"

FIP_START=192.168.1.91
FIP_END=192.168.64.97
FIP_GATEWAY=192.168.1.1
FIP_CIDR=192.168.1.0/8
TENANT_NET_DNS="8.8.8.8 8.8.4.4"

KOLLA_INTERNAL_VIP_ADDRESS=192.168.1.254

KOLLA_BRANCH=stable/ocata
KOLLA_OPENSTACK_VERSION=4.0.0

DOCKER_NAMESPACE=kolla

sudo tee /etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
TYPE="Ethernet"
BOOTPROTO="none"
DEFROUTE="yes"
IPV4_FAILURE_FATAL="no"
IPV6INIT="yes"
IPV6_AUTOCONF="yes"
IPV6_DEFROUTE="yes"
IPV6_FAILURE_FATAL="no"
IPV6_ADDR_GEN_MODE="stable-privacy"
NAME="eth0"
DEVICE="eth0"
ONBOOT="yes"
IPADDR="192.168.1.44"
PREFIX="24"
GATEWAY="192.168.1.1"
DNS1="192.168.1.1"
IPV6_PEERDNS="yes"
IPV6_PEERROUTES="yes"
IPV6_PRIVACY="no"
EOF

sudo tee /etc/sysconfig/network-scripts/ifcfg-eth1 <<EOF
TYPE="Ethernet"
BOOTPROTO="none"
NAME="eth1"
DEVICE="eth1"
ONBOOT="yes"
EOF

sudo tee /etc/sysconfig/network-scripts/ifcfg-eth2 <<EOF
TYPE="Ethernet"
BOOTPROTO="none"
NAME="eth2"
DEVICE="eth2"
ONBOOT="yes"
EOF

for iface in eth0 eth1 eth2
do
    sudo ifdown $iface || true
    sudo ifup $iface
done

# Get Docker and Ansible
sudo systemctl disable firewalld
sudo systemctl stop firewalld
sudo systemctl disable NetworkManager
sudo systemctl stop NetworkManager
sudo systemctl enable network
sudo systemctl start network
sudo yum install epel-release -y
sudo yum install python-pip -y
sudo pip install -U pip
sudo yum install  -y python-devel libffi-devel gcc openssl-devel
sudo pip install -U ansible
curl -sSL https://get.docker.io | sudo bash
sudo yum install ntp -y
sudo systemctl enable ntpd.service
sudo systemctl start ntpd.service
#sudo systemctl stop libvirtd.service
#sudo systemctl disable libvirtd.service
sudo pip install -U docker-py
sudo pvcreate /dev/sdb /dev/sdc
sudo vgcreate cinder-volumes /dev/sdb /dev/sdc
# Install Kolla
cd ~
sudo pip install kolla-ansible
sudo cp -r /usr/share/kolla-ansible/etc_examples/kolla /etc/kolla/
sudo cp /usr/share/kolla-ansible/ansible/inventory/* .

sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/kolla.conf <<-'EOF'
[Service]
MountFlags=shared
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker

# Get the container images for the OpenStack services
sudo sed -i '/#kolla_base_distro/i kolla_base_distro: "centos"' /etc/kolla/globals.yml
sudo sed -i '/#docker_namespace/i docker_namespace: "'$DOCKER_NAMESPACE'"' /etc/kolla/globals.yml
sudo sed -i '/#openstack_release/i openstack_release: "'$KOLLA_OPENSTACK_VERSION'"' /etc/kolla/globals.yml
sudo kolla-ansible pull


sudo sed -i '/#enable_cinder/i enable_cinder: "yes"' /etc/kolla/globals.yml
sudo sed -i '/#enable_cinder_backend_lvm/i enable_cinder_backend_lvm: "yes"' /etc/kolla/globals.yml
sudo sed -i '/#cinder_volume_group/i cinder_volume_group: "cinder-volumes"' /etc/kolla/globals.yml
sudo sed -i 's/^kolla_internal_vip_address:\s.*$/kolla_internal_vip_address: "'$KOLLA_INTERNAL_VIP_ADDRESS'"/g' /etc/kolla/globals.yml
sudo sed -i '/#network_interface/i network_interface: "eth0"' /etc/kolla/globals.yml
sudo sed -i '/#neutron_external_interface/i neutron_external_interface: "eth1"' /etc/kolla/globals.yml

sudo mkdir -p /etc/kolla/config/neutron

# remove vxlan stuff
sed -i '/ml2_type_vxlan/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2
sed -i '/vni_ranges/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2
sed -i '/vxlan_group/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2
sed -i '/tunnel_types/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2
sed -i '/l2_population/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2
sed -i '/arp_responder/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2
sed -i '/\[agent\]/d' /usr/share/kolla-ansible/roles/neutron/templates/ml2_conf.ini.j2

sudo tee /etc/kolla/config/neutron/ml2_conf.ini <<-'EOF'
[ml2]
type_drivers = flat,vlan
tenant_network_types = flat,vlan
mechanism_drivers = openvswitch,hyperv
extension_drivers = port_security
[ml2_type_vlan]
network_vlan_ranges = physnet2:500:2000
[ovs]
bridge_mappings = physnet1:br-ex,physnet2:br-data
EOF

# kolla-ansible prechecks fails if the hostname in the hosts file is set to 127.0.1.1
MGMT_IP=$(sudo ip addr show eth0 | sed -n 's/^\s*inet \([0-9.]*\).*$/\1/p')
# sudo bash -c "echo $MGMT_IP $(hostname) >> /etc/hosts"

# Generate random passwords for all OpenStack services
sudo kolla-genpwd

#sudo kolla-ansible prechecks -i all-in-one
sudo kolla-ansible -i  all-in-one bootstrap-servers
#sudo kolla-ansible deploy -i all-in-one
#sudo kolla-ansible post-deploy -i all-in-one

sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-br br-data
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-port br-data eth2
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-port br-data phy-br-data || true
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface phy-br-data type=patch
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-port br-int int-br-data || true
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface int-br-data type=patch
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface phy-br-data options:peer=int-br-data
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface int-br-data options:peer=phy-br-data


# Remove unneeded Nova containers
#for name in nova_compute nova_ssh nova_libvirt
#do
#    for id in $(sudo docker ps -q -a -f name=$name)
#    do
#        sudo docker stop $id
#        sudo docker rm $id
#    done
#done


#sudo add-apt-repository cloud-archive:newton -y && apt-get update
sudo pip install python-novaclient
sudo pip install python-neutronclient
sudo pip install python-keystoneclient
sudo pip install python-keystoneclient
sudo pip install python-cinderclient

source /etc/kolla/admin-openrc.sh

wget https://cloudbase.it/downloads/cirros-0.3.4-x86_64.vhdx.gz
gunzip cirros-0.3.4-x86_64.vhdx.gz
openstack image create --public --property hypervisor_type=hyperv --disk-format vhd --container-format bare --file cirros-0.3.4-x86_64.vhdx cirros-gen1-vhdx
rm cirros-0.3.4-x86_64.vhdx

# Create the private network
neutron net-create private-net --provider:physical_network physnet2 --provider:network_type vlan
neutron subnet-create private-net 10.10.10.0/24 --name private-subnet --allocation-pool start=10.10.10.50,end=10.10.10.200 --dns-nameservers list=true $TENANT_NET_DNS --gateway 10.10.10.1

# Create the public network
neutron net-create public-net --shared --router:external --provider:physical_network physnet1 --provider:network_type flat
neutron subnet-create public-net --name public-subnet --allocation-pool start=$FIP_START,end=$FIP_END --disable-dhcp --gateway $FIP_GATEWAY $FIP_CIDR

# create a router and hook it the the networks
neutron router-create router1

neutron router-interface-add router1 private-subnet
neutron router-gateway-set router1 public-net

# Create sample flavors
nova flavor-create m1.nano 11 96 1 1
nova flavor-create m1.tiny 1 512 1 1
nova flavor-create m1.small 2 2048 20 1
nova flavor-create m1.medium 3 4096 40 2
nova flavor-create m1.large 5 8192 80 4
nova flavor-create m1.xlarge 6 16384 160 8
