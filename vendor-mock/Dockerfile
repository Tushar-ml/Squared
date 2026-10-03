FROM python:3.12-slim
WORKDIR /srv
RUN pip install --no-cache-dir fastapi==0.115.6 uvicorn==0.34.0
COPY main.py .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8090"]
