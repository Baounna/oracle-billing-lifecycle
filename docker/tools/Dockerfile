# Tools container: Python benchmark harness + Oracle SQLcl.
# Nothing is installed on the host; the project folder is mounted at /work.
FROM python:3.12-slim-bookworm

# Java runtime for SQLcl
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-17-jre-headless curl unzip \
 && rm -rf /var/lib/apt/lists/*

# Oracle SQLcl (free command-line client, pinned version) - interactive use:
#   docker compose run --rm tools sql TELCO_ANALYST@//host.docker.internal:1521/orclpdb1
ARG SQLCL_VERSION=26.3.1.301.1413
RUN curl -fsSL -o /tmp/sqlcl.zip https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-${SQLCL_VERSION}.zip \
 && unzip -q /tmp/sqlcl.zip -d /opt \
 && rm /tmp/sqlcl.zip \
 && ln -s /opt/sqlcl/bin/sql /usr/local/bin/sql

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

ENV PYTHONPATH=/work/python \
    PYTHONUNBUFFERED=1
WORKDIR /work
