FROM python:3.14-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY auth.py discovery.py main.py models.py sessions.py settings.py signaling.py ./
USER 10001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--ws-max-size", "32768", "--no-access-log"]
