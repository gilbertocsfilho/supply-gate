FROM python:3.12-slim

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip \
    && python -m pip install devpi-server devpi-web

COPY docker/devpi/entrypoint.sh /entrypoint.sh

RUN chmod 755 /entrypoint.sh

EXPOSE 3141

ENTRYPOINT ["/entrypoint.sh"]
