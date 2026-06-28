FROM docker.io/library/postgres:17

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pgbackrest \
        openssh-client && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/lib/postgresql/.ssh && \
    chown postgres:postgres /var/log/pgbackrest /var/lib/postgresql/.ssh && \
    chmod 700 /var/lib/postgresql/.ssh

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY entrypoint.sh /pgbackrest-entrypoint.sh
RUN chmod +x /pgbackrest-entrypoint.sh

ENTRYPOINT ["/pgbackrest-entrypoint.sh"]
CMD ["postgres"]
