FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      curl \
      docker.io \
      tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -m -s /bin/bash appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

RUN chown -R appuser:appuser /app

USER appuser

ENTRYPOINT ["tini", "--"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8400"]
