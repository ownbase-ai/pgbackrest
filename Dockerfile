FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pgbackrest \
        openssh-server \
        postgresql-client \
        cron \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash pgbackrest && \
    # useradd creates the home dir as 750; root loses access with DropCapability=ALL.
    # Set 755 so the entrypoint (root, no CAP_DAC_OVERRIDE) can traverse into it.
    chmod 755 /home/pgbackrest && \
    mkdir -p \
        /var/lib/pgbackrest \
        /var/log/pgbackrest \
        /etc/pgbackrest \
        /home/pgbackrest/.ssh \
        /run/sshd && \
    chown -R pgbackrest:pgbackrest \
        /var/lib/pgbackrest \
        /var/log/pgbackrest && \
    # Keep .ssh owned by root so the entrypoint (root, CAP_DAC_OVERRIDE dropped)
    # can write authorized_keys. sshd accepts root-owned authorized_keys files
    # provided they are not group/world-writable (modes below satisfy that).
    chmod 755 /home/pgbackrest/.ssh && \
    touch /home/pgbackrest/.ssh/authorized_keys && \
    chmod 644 /home/pgbackrest/.ssh/authorized_keys

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/var/lib/pgbackrest", "/var/log/pgbackrest"]

# sshd for pgbackrest repo-host communication
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
