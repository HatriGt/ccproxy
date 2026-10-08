# Usage tracker: drains CLIProxyAPI's usage-queue into SQLite for day-wise
# per-user token reporting. Also runs the 5-hour auto-hold guard loop.
# Stdlib only (urllib + sqlite3), no pip installs.
FROM python:3.12-alpine

COPY images/usage-tracker/tracker.py /app/tracker.py
COPY images/usage-tracker/guard.py /app/guard.py
COPY images/usage-tracker/usage_cli.py /usr/local/bin/usage-cli
RUN chmod +x /usr/local/bin/usage-cli /app/tracker.py /app/guard.py

WORKDIR /app
CMD ["python3", "/app/tracker.py"]
