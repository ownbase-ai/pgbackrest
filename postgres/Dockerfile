FROM postgres:17

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pgbackrest \
        openssh-client && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/pgbackrest /var/log/pgbackrest && \
    chown postgres:postgres /var/log/pgbackrest

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY entrypoint.sh /pgbackrest-entrypoint.sh
RUN chmod +x /pgbackrest-entrypoint.sh

ENTRYPOINT ["/pgbackrest-entrypoint.sh"]
CMD ["postgres"]
