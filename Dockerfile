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
    mkdir -p \
        /var/lib/pgbackrest \
        /var/log/pgbackrest \
        /etc/pgbackrest \
        /home/pgbackrest/.ssh \
        /run/sshd && \
    chmod 700 /home/pgbackrest/.ssh && \
    chown -R pgbackrest:pgbackrest \
        /var/lib/pgbackrest \
        /var/log/pgbackrest \
        /home/pgbackrest/.ssh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/var/lib/pgbackrest", "/var/log/pgbackrest"]

# sshd for pgbackrest repo-host communication
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
