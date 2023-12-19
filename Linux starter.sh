#!/bin/bash
apt update && apt upgrade -y
sudo updatedb && locate -e bench-repo

####################Sublime Text ####################
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/sublimehq-archive.gpg > /dev/null
echo "deb https://download.sublimetext.com/ apt/stable/" | sudo tee /etc/apt/sources.list.d/sublime-text.list
sudo apt-get update -y
sudo apt-get install sublime-text -y
##################### Sublime Text ####################
sudo apt-get install apt-transport-https -y 
##################### TOR #########################
apt install tor -y
###################### pip2.7 #####################
wget https://bootstrap.pypa.io/pip/2.7/get-pip.py
sudo python2.7 get-pip.py 
#######################Pyrit and more installer#######################
git clone https://github.com/hacker3983/pyrit-installer && cd pyrit-installer && sudo bash install.sh
###################### WIFI DRIVER RTL8821CU ##########################
#!/bin/bash
mkdir -p ~/build
cd ~/build
git clone https://github.com/brektrou/rtl8821CU.git
apt-get install dkms -y
cd ~/build/rtl8821CU
make
apt install bc -y
apt install libwacom9 libwacom-common=2.1.0-2
apt update -y && apt upgrade -y && apt dist-upgrade
###################################################################
#sudo reboot
sudo apt install linux-headers-$(uname -r) -y
cd ~/build/rtl8821CU
make
sudo make install -y
####################### WIFI DRIVER 2 rtl8812au ########################
git clone https://github.com/aircrack-ng/rtl8812au.git
cd rtl8812au/
make dkms_install
###################### Extra Tools ###########################
apt install hcxtools -y
apt install hcxdumptool -y 
apt install airgeddon -y 
apt install beef-xss -y 
apt install asleap -y 
apt install bettercap -y 
apt install hostapd-wpe -y 
####################### Kali metapackages ########################
sudo apt install -y kali-tools-802-11
######################## Fluxion and Tools ########################
git clone https://github.com/FluxionNetwork/fluxion.git
cd fluxion 
./fluxion.sh -i 
