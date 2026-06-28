FROM docker.io/library/postgres:17

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pgbackrest \
        openssh-client && \
    rm -rf /var/lib/apt/lists/*

# Pre-create every directory the entrypoint writes to and own it by the
# postgres user (UID 999).  OwnBase runs user containers as the image user
# (User=999 in the Quadlet) with DropCapability=ALL + NoNewPrivileges=true,
# which prevents gosu/su-exec from switching UIDs at runtime.  By owning
# all writable paths in the image we skip the root→postgres transition
# entirely and let docker-entrypoint.sh run directly as UID 999.
RUN mkdir -p \
        /etc/pgbackrest \
        /var/log/pgbackrest \
        /var/lib/postgresql/.ssh \
        /docker-entrypoint-initdb.d && \
    chown -R postgres:postgres \
        /etc/pgbackrest \
        /var/log/pgbackrest \
        /var/lib/postgresql/.ssh \
        /docker-entrypoint-initdb.d && \
    chmod 700 /var/lib/postgresql/.ssh

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

COPY entrypoint.sh /pgbackrest-entrypoint.sh
RUN chmod +x /pgbackrest-entrypoint.sh

USER postgres
ENTRYPOINT ["/pgbackrest-entrypoint.sh"]
CMD ["postgres"]
