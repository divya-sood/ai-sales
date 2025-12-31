#!/usr/bin/env bash
set -euo pipefail

echo "🚀 AI Sales Call Assistant - Starting All Services"
echo "=================================================="

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"

# Detect if running on Windows (Git Bash)
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
  PYTHON_CMD="python"
  VENV_ACTIVATE="Scripts/activate"
  VENV_PYTHON="Scripts/python"
  VENV_UVICORN="Scripts/uvicorn"
else
  PYTHON_CMD="python3"
  VENV_ACTIVATE="bin/activate"
  VENV_PYTHON="bin/python"
  VENV_UVICORN="bin/uvicorn"
fi

# Function to check if a port is in use
check_port() {
  local port=$1
  if command -v netstat >/dev/null 2>&1; then
    if netstat -an | grep -q ":$port "; then
      return 0  # Port is in use
    fi
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -i ":$port" >/dev/null 2>&1; then
      return 0  # Port is in use
    fi
  fi
  return 1  # Port is free
}

# Function to wait for service to be ready
wait_for_service() {
  local url=$1
  local service_name=$2
  local max_attempts=30
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    if curl -s "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    ((attempt++))
  done
  echo "❌ $service_name failed to start within timeout"
  return 1
}

# Check if ports are available
if check_port 8000; then
  echo "⚠️  Port 8000 is already in use by another process"
  exit 1
fi
if check_port 3000; then
  echo "⚠️  Port 3000 is already in use by another process"
  exit 1
fi

# Backend Setup
if [ ! -f "$ROOT_DIR/backend/.venv/$VENV_PYTHON" ]; then
  cd "$ROOT_DIR/backend"
  $PYTHON_CMD -m venv .venv > /dev/null 2>&1
  source ".venv/$VENV_ACTIVATE"
  pip install -q -r requirements.txt > /dev/null 2>&1
  cd "$ROOT_DIR"
else
  cd "$ROOT_DIR/backend"
  source ".venv/$VENV_ACTIVATE"
  if ! python -c "import pandas" 2>/dev/null; then
    pip install -q --no-cache-dir fastapi uvicorn python-dotenv pandas > /dev/null 2>&1 || true
  fi
  cd "$ROOT_DIR"
fi

# Check if .env file exists
if [ ! -f "$ROOT_DIR/backend/.env" ]; then
  cat > "$ROOT_DIR/backend/.env" << EOF
# MongoDB Configuration
DATABASE_URL=mongodb://localhost:27017
DB_NAME=agent_starter_db

# Email Configuration
SMTP_SERVER=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
ADMIN_EMAIL=meegadavamsi76@gmail.com

# LiveKit Configuration
LIVEKIT_API_KEY=YOUR_LIVEKIT_API_KEY
LIVEKIT_API_SECRET=YOUR_LIVEKIT_API_SECRET
EOF
fi

cd "$ROOT_DIR/backend"
nohup bash -c "source .venv/$VENV_ACTIVATE && uvicorn main:app --host 0.0.0.0 --port 8000 --reload" > "$LOG_DIR/backend.log" 2>&1 &
BACKEND_PID=$!
cd "$ROOT_DIR"

# Wait for backend to be ready
if wait_for_service "http://localhost:8000/health" "Backend API"; then
  echo "✅ Backend running: http://localhost:8000"
else
  echo "❌ Backend failed to start. Check logs: tail -f $LOG_DIR/backend.log"
  exit 1
fi

# Frontend Setup
(cd "$ROOT_DIR/agent-starter-react" && npx -y pnpm@9.12.2 install --frozen-lockfile > "$LOG_DIR/frontend-install.log" 2>&1)

# Check if frontend .env.local exists and has BACKEND_URL
if [ ! -f "$ROOT_DIR/agent-starter-react/.env.local" ] || ! grep -q "BACKEND_URL" "$ROOT_DIR/agent-starter-react/.env.local"; then
  echo "BACKEND_URL=http://localhost:8000" >> "$ROOT_DIR/agent-starter-react/.env.local"
fi

nohup bash -c "cd '$ROOT_DIR/agent-starter-react' && NEXT_PUBLIC_BACKEND_URL=http://localhost:8000 npx -y pnpm@9.12.2 dev" > "$LOG_DIR/frontend.log" 2>&1 &
FRONTEND_PID=$!

# Wait for frontend to be ready
if wait_for_service "http://localhost:3000" "Frontend"; then
  echo "✅ Frontend running: http://localhost:3000"
else
  echo "❌ Frontend failed to start. Check logs: tail -f $LOG_DIR/frontend.log"
fi

# Agent Setup
if [ ! -f "$ROOT_DIR/agent/venv/$VENV_PYTHON" ]; then
  cd "$ROOT_DIR/agent"
  $PYTHON_CMD -m venv venv > /dev/null 2>&1
  source "venv/$VENV_ACTIVATE"
  pip install -q -r requirements.txt > /dev/null 2>&1
  cd "$ROOT_DIR"
else
  cd "$ROOT_DIR/agent"
  source "venv/$VENV_ACTIVATE"
  if ! python -c "import livekit.agents" 2>/dev/null && ! python -c "import livekit_agents" 2>/dev/null; then
    pip install -q -r requirements.txt > /dev/null 2>&1
  fi
  cd "$ROOT_DIR"
fi

cd "$ROOT_DIR/agent"
if [ ! -f ".env" ]; then
  echo "⚠️  Agent .env file not found. Configure agent/.env with LiveKit credentials"
fi
nohup bash -c "cd '$ROOT_DIR/agent' && source venv/$VENV_ACTIVATE && python app.py dev" > "$LOG_DIR/agent.log" 2>&1 &
AGENT_PID=$!
cd "$ROOT_DIR"
echo "✅ LiveKit Agent running"

echo ""
echo "🎉 All Services Started Successfully!"
echo "====================================="
echo ""
echo "🌐 Frontend:  http://localhost:3000"
echo "📊 Backend:   http://localhost:8000"
echo "📖 API Docs:  http://localhost:8000/docs"
echo ""
echo "📁 Logs: $LOG_DIR/"


