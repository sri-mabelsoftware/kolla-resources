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


# kolla-ansible prechecks fails if the hostname in the hosts file is set to 127.0.1.1
MGMT_IP=$(sudo ip addr show eth0 | sed -n 's/^\s*inet \([0-9.]*\).*$/\1/p')
# sudo bash -c "echo $MGMT_IP $(hostname) >> /etc/hosts"

# Generate random passwords for all OpenStack services
sudo kolla-genpwd

#sudo kolla-ansible -i  all-in-one bootstrap-servers
sudo kolla-ansible prechecks -i all-in-one
sudo kolla-ansible deploy -i all-in-one
sudo kolla-ansible post-deploy -i all-in-one

sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-br br-data
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-port br-data eth2
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-port br-data phy-br-data || true
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface phy-br-data type=patch
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl add-port br-int int-br-data || true
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface int-br-data type=patch
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface phy-br-data options:peer=int-br-data
sudo docker exec --privileged openvswitch_vswitchd ovs-vsctl set interface int-br-data options:peer=phy-br-data


# Remove unneeded Nova containers
for name in nova_compute nova_ssh nova_libvirt
do
    for id in $(sudo docker ps -q -a -f name=$name)
    do
        sudo docker stop $id
        sudo docker rm $id
    done
done


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
