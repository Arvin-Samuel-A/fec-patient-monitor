FROM python:3.11-slim
WORKDIR /app

# Install uv for fast, reproducible dependency installation
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

COPY pyproject.toml .
RUN uv pip install --system -r pyproject.toml

COPY main.py .

ENV PORT=8081

EXPOSE $PORT

CMD uvicorn main:app \
    --host 0.0.0.0 \
    --port $PORT
