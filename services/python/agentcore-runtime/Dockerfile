FROM public.ecr.aws/docker/library/python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# AgentCore runtime looks for your python entrypoint in the container.
# The bedrock-agentcore SDK handles bootstrapping when the container runs.
CMD ["python", "app.py"]
