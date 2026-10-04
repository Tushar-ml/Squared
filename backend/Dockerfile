FROM python:3.12-slim
WORKDIR /srv
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 TZ=UTC
# INSTALL_DEV=1 (docker-compose) adds pytest, hypothesis and moto; production images leave them out
ARG INSTALL_DEV=0
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements.txt && \
    if [ "$INSTALL_DEV" = "1" ]; then pip install --no-cache-dir -r requirements-dev.txt; fi
COPY . .
RUN useradd --create-home app && mkdir -p uploads && chown -R app /srv
USER app
EXPOSE 8080
# behind DigitalOcean's load balancer: trust its X-Forwarded-* headers for scheme and client IP
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips", "*"]
