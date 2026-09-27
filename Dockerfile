FROM debian:12-slim

# Avoid interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install the tools required by the project's scripts
RUN apt-get update && apt-get install -y \
    systemd \
    systemd-sysv \
    cron \
    curl \
    iputils-ping \
    bc \
    netcat-openbsd \
    nmap \
    openssh-client \
    openssh-server \
    procps \
    sudo \
    nano \
    iproute2 \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Remove unnecessary systemd units that cause issues in containers
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp*

# Enable ssh and cron services for tests with services.sh
RUN systemctl enable ssh && systemctl enable cron

# Create the non-root user "supervisor" for testing
RUN useradd -m -s /bin/bash supervisor && \
    echo "supervisor:password" | chpasswd && \
    adduser supervisor sudo

# Allow supervisor to use sudo without a password
RUN echo "supervisor ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/supervisor

# Create test directories for the project's scripts
RUN mkdir -p /home/supervisor/dir_Prueba1 && touch /home/supervisor/dir_Prueba1/archivo1.txt
RUN mkdir -p /home/supervisor/dir_Prueba2 && touch /home/supervisor/dir_Prueba2/archivo2.txt

# Create the log directory
RUN mkdir -p /var/log && touch /var/log/automated_gestion.log && \
    chown supervisor:supervisor /var/log && chown supervisor:supervisor /var/log/automated_gestion.log

# Set the working directory where the scripts will be mounted
WORKDIR /workspace

# Command to keep the container interactive
CMD ["/sbin/init"]