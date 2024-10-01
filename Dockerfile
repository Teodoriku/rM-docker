# Global config
#ARG toltec_image=ghcr.io/toltec-dev/base:v3.1
ARG toltec_image=ghcr.io/toltec-dev/base:v3.2
ARG rm2_stuff_tag=v0.1.2
#ARG fw_version=3.5.2.1807
ARG fw_version=3.11.2.5
# ARG linux_release=5.8.18
ARG linux_release=5.8.18

# Step 1: Build Linux for the emulator
FROM $toltec_image AS linux-build

RUN apt-get update && \
    apt-get install -y bison bc lzop libssl-dev flex

ARG linux_release

RUN curl -o linux.tar.xz https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$linux_release.tar.xz && \
    mkdir -p /opt/linux && cd /opt/linux && tar -xf /linux.tar.xz && rm /linux.tar.xz

WORKDIR /opt/linux/linux-$linux_release

# Add a device tree with machine name set to 'reMarkable 2.0'
RUN cp arch/arm/boot/dts/imx7d-sbc-imx7.dts arch/arm/boot/dts/imx7d-rm.dts && \
    sed -i 's/CompuLab SBC-iMX7/reMarkable 2.0/' arch/arm/boot/dts/imx7d-rm.dts && \
    sed -i 's/imx7d-sbc-imx7.dtb/imx7d-sbc-imx7.dtb imx7d-rm.dtb/' arch/arm/boot/dts/Makefile

# Default imx7 config, enable uinput and disable all modules, add necessary kernel options
RUN make O=imx7 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- imx_v6_v7_defconfig && \
    sed -i 's/# CONFIG_INPUT_UINPUT is not set/CONFIG_INPUT_UINPUT=y/' imx7/.config && \
    sed -i 's/=m/=n/' imx7/.config && \
    echo "CONFIG_DUMMY=y" >> imx7/.config && \
    echo "CONFIG_MAC80211_HWSIM=y" >> imx7/.config && \
    echo "CONFIG_VIRT_WIFI=y" >> imx7/.config && \
    echo "CONFIG_BRIDGE=y" >> imx7/.config && \
    echo "CONFIG_IP_NF_NAT=m" >> imx7/.config && \
    echo "CONFIG_NF_NAT_IPV4=m" >> imx7/.config && \
    echo "CONFIG_IP_NF_TARGET_MASQUERADE=m" >> imx7/.config && \
    echo "CONFIG_NF_TABLES=m" >> imx7/.config && \
    echo "CONFIG_NF_TABLES_IPV4=m" >> imx7/.config && \
    echo "CONFIG_NF_NAT=m" >> imx7/.config && \
    echo "CONFIG_NETFILTER=y" >> imx7/.config && \
    echo "CONFIG_NETFILTER_XTABLES=y" >> imx7/.config && \
    echo "CONFIG_IP_NF_FILTER=y" >> imx7/.config && \
    echo "CONFIG_NF_CONNTRACK=m" >> imx7/.config

# Build the kernel with the modified config
RUN make O=imx7 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j $(nproc) && \
    cp imx7/arch/arm/boot/zImage /opt && \
    cp imx7/arch/arm/boot/dts/imx7d-rm.dtb /opt && \
    rm -rf imx7

# Step 2: rootfs
FROM linuxkit/guestfs:f85d370f7a3b0749063213c2dd451020e3a631ab AS rootfs

WORKDIR /opt
ARG TARGETARCH

# Install dependencies
ADD https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-${TARGETARCH} \
    /usr/local/bin/jq

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      python3 \
      python3-protobuf && \
    chmod +x /usr/local/bin/jq && \
    git clone https://github.com/ddvk/stuff.git /opt/stuff

ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

RUN sleep 45

ADD get_update.sh /opt
ADD updates.json /opt

ARG fw_version
RUN /opt/get_update.sh download $fw_version && \
    python3 /opt/stuff/extractor/extractor.py /opt/fw.signed /opt/rootfs.ext4

# Make the rootfs image
ADD make_rootfs.sh /opt
RUN ./make_rootfs.sh /opt/rootfs.ext4

# Step 3: QEMU setup
FROM debian:bookworm AS qemu-debug

RUN apt-get update && \
    apt-get install --no-install-recommends -y qemu-system-arm qemu-utils ssh netcat-openbsd net-tools vim iputils-ping traceroute iproute2

RUN mkdir -p /opt/root

COPY --from=linux-build /opt/zImage /opt
COPY --from=linux-build /opt/imx7d-rm.dtb /opt
COPY --from=rootfs /opt/rootfs.qcow2 /opt/root

ADD bin /opt/bin
ENV PATH=/opt/bin:$PATH

FROM qemu-debug AS qemu-base

# First boot, disable xochitl and reboot service, and save state
RUN run_vm -serial null -daemonize && \
    wait_ssh && \
    in_vm systemctl mask remarkable-fail && \
    in_vm systemctl mask xochitl && \
    save_vm

# Mount to persist rootfs
VOLUME /opt/root

# SSH access
EXPOSE 22/tcp
# QEMU monitor TCP port
EXPOSE 5555/tcp
# For rm2fb
EXPOSE 8888/tcp

CMD run_vm -nographic

FROM qemu-base AS qemu-toltec

RUN run_vm -serial null -daemonize && \
    wait_ssh && \
    in_vm 'while ! timedatectl status | grep "synchronized: yes"; do sleep 1; done' && \
    in_vm wget https://raw.githubusercontent.com/toltec-dev/toltec/testing/scripts/bootstrap/bootstrap && \
    in_vm env bash bootstrap --force && \
    save_vm

# Step 4: Build rm2fb-emu and hostapd for the debian host...
FROM debian:bookworm AS rm2fb-host

RUN apt-get update && \
    apt-get install -y git clang cmake ninja-build libsdl2-dev libevdev-dev libsystemd-dev \
    gcc-arm-linux-gnueabihf make curl ca-certificates wget xxd git-lfs

ARG rm2_stuff_tag
RUN mkdir -p /opt && \
    git clone https://github.com/timower/rM2-stuff.git /opt/rm2-stuff && \
    cd /opt/rm2-stuff && git reset --hard $rm2_stuff_tag && git lfs pull
WORKDIR /opt/rm2-stuff

# Build rm2fb-emu
RUN cmake --preset dev-host && cmake --build build/host --target rm2fb-emu

# Compile and integrate hostapd
# Create symbolic links for the expected toolchain
RUN ln -s /usr/bin/arm-linux-gnueabihf-gcc /usr/bin/armv7l-unknown-linux-gnueabihf-gcc && \
    ln -s /usr/bin/arm-linux-gnueabihf-ar /usr/bin/armv7l-unknown-linux-gnueabihf-ar

WORKDIR /opt

# Download the build script and compile hostapd
ADD https://github.com/user-attachments/files/16921363/build.sh.txt /opt/build.sh
RUN chmod +x /opt/build.sh && \
    /opt/build.sh 2>&1 | tee /opt/build_output.log

# Download rm2display.ipk
RUN wget --no-check-certificate -O /opt/rm2display.ipk https://github.com/timower/rM2-stuff/releases/download/v0.1.2/rm2display.ipk

# Step 5: Integrate rm2fb and hostapd
FROM qemu-toltec AS qemu-rm2fb

RUN mkdir -p /opt/rm2fb

COPY --from=rm2fb-host /opt/rm2-stuff/build/host/tools/rm2fb-emu/rm2fb-emu /opt/bin
COPY --from=rm2fb-host /opt/hostapd-2.11/hostapd/hostapd /opt/hostapd
COPY --from=rm2fb-host /opt/rm2display.ipk /opt/rm2display.ipk

ARG rm2_stuff_tag
RUN run_vm -serial null -daemonize && \
    wait_ssh && \
    in_vm wget https://github.com/timower/rM2-stuff/releases/download/$rm2_stuff_tag/rm2display.ipk && \
    in_vm opkg install rm2display.ipk && \
    save_vm

RUN apt-get update && \
    apt-get install -y libevdev2 libsdl2-2.0-0

# Create the hostapd.conf file dynamically
RUN echo "interface=wlan1\n\
country_code=DE\n\
ssid=VirtualWifi\n\
channel=0\n\
hw_mode=b\n\
wpa=2\n\
wpa_key_mgmt=WPA-PSK\n\
wpa_pairwise=TKIP CCMP\n\
wpa_passphrase=12345678\n\
auth_algs=3\n\
beacon_int=100\n\
ctrl_interface=/var/run/hostapd\n\
ignore_broadcast_ssid=0" > /opt/hostapd.conf

# Recreate the entire dhcpcd.conf
RUN echo "hostname\n\
duid\n\
persistent\n\
option rapid_commit\n\
option domain_name_servers, domain_name, domain_search, host_name\n\
option classless_static_routes\n\
option interface_mtu\n\
require dhcp_server_identifier\n\
slaac private\n\
interface wlan0\n\
static ip_address=10.0.2.20/24\n\
static routers=10.0.2.2\n\
static domain_name_servers=9.9.9.9\n\
interface wlan1\n\
static ip_address=10.0.2.21/24\n\
static routers=10.0.2.2\n\
static domain_name_servers=9.9.9.9\n\
interface br0\n\
static ip_address=10.0.2.30/24\n\
static routers=10.0.2.2\n\
static domain_name_servers=9.9.9.9" > /opt/dhcpcd.conf

# Create the dhcpcd.service file dynamically
RUN echo "[Unit]\n\
Description=dhcpcd on all interfaces\n\
Wants=network.target\n\
Before=network.target\n\
After=systemd-udevd.service network-pre.target systemd-sysusers.service systemd-sysctl.service\n\
\n\
[Service]\n\
Type=forking\n\
PIDFile=/run/dhcpcd.pid\n\
ExecStart=/usr/sbin/dhcpcd -4 -b --allowinterfaces \"eth*\",wlan0,wlan1,br0\n\
ExecStop=/usr/sbin/dhcpcd -x\n\
Restart=on-failure\n\
\n\
[Install]\n\
WantedBy=multi-user.target" > /opt/dhcpcd.service

RUN run_vm -serial null -daemonize && \
    wait_ssh && \
    scp -o StrictHostKeyChecking=no /opt/dhcpcd.conf root@localhost:/etc/dhcpcd.conf && \
    scp -o StrictHostKeyChecking=no /opt/dhcpcd.service root@localhost:/lib/systemd/system/dhcpcd.service && \
    scp -o StrictHostKeyChecking=no /opt/hostapd root@localhost:/bin/hostapd && \
    scp -o StrictHostKeyChecking=no /opt/hostapd.conf root@localhost:/opt/hostapd.conf && \
    scp -o StrictHostKeyChecking=no /opt/rm2display.ipk root@localhost:/opt/rm2display.ipk && \
    in_vm "systemctl daemon-reload" && \
    in_vm ip link set wlan1 up && \
    in_vm "systemctl restart dhcpcd" && \
    in_vm chmod +x /bin/hostapd && \
    in_vm "( /bin/hostapd -dd /opt/hostapd.conf -B > /tmp/hostapd.log 2>&1 )" && \
    in_vm "echo 'nameserver 9.9.9.9' | tee /etc/resolv.conf" && \
    in_vm "echo 1 | tee /proc/sys/net/ipv4/ip_forward" && \
    in_vm opkg install iptables && \
    in_vm opkg install bridge && \
    in_vm brctl addbr br0 && \
    in_vm brctl addif br0 wlan1 && \
    in_vm brctl addif br0 eth0 && \
    in_vm "systemctl restart dhcpcd" && \
    save_vm

CMD run_xochitl
